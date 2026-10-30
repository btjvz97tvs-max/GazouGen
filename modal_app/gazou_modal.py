"""
画像生成アプリを Modal（クラウドGPU）で動かす定義

しくみ
- ui      : 画面（Gradio）。安い CPU で動く。パスワード付き。
- Worker  : ComfyUI を動かす GPU。生成するときだけ起動し、5分使わなければ自動で止まる。
- download: モデルを Modal のボリューム（gazougen-data）に保存する。CPU で動く。

GitHub Actions の「Modal」ワークフローから使う想定（PC 不要）。
手元で使う場合：
  modal run modal_app/gazou_modal.py::download --which both
  modal deploy modal_app/gazou_modal.py
"""
import json
import os
import subprocess
import time
from pathlib import Path

import modal

APP_NAME = "gazougen"
VOLUME_NAME = "gazougen-data"
SECRET_NAME = "gazougen-secret"
GPU = os.environ.get("GAZOU_GPU", "L4")      # L4（おすすめ）/ A10G / T4
GPU_IDLE_SECONDS = 300                        # 生成が終わってから GPU を止めるまでの秒数
COMFY_REF = "v0.41.3"                         # ComfyUI のバージョン（固定）
GRADIO_VERSION = "5.49.1"

HERE = Path(__file__).parent
DATA = "/data"
CKPT_DIR = f"{DATA}/checkpoints"

app = modal.App(APP_NAME)
vol = modal.Volume.from_name(VOLUME_NAME, create_if_missing=True)
secret = modal.Secret.from_name(SECRET_NAME)

# ------------------------------------------------------------
# GPU 側：ComfyUI
# ------------------------------------------------------------
gpu_image = (
    modal.Image.debian_slim(python_version="3.11")
    .apt_install("git", "libgl1", "libglib2.0-0")
    .run_commands(
        f"git clone --depth 1 --branch {COMFY_REF} https://github.com/comfyanonymous/ComfyUI /root/ComfyUI"
    )
    # Modal の GPU は CUDA 13 対応なので、cu130 版の PyTorch を入れる
    .pip_install("torch", "torchvision", index_url="https://download.pytorch.org/whl/cu130")
    .run_commands("pip install -r /root/ComfyUI/requirements.txt")
    # モデルはボリューム（/data/checkpoints）から読む
    .run_commands(
        r"printf 'gazou:\n  base_path: /data\n  checkpoints: checkpoints\n' > /root/extra_model_paths.yaml"
    )
)


def _http(method, url, data=None, timeout=30):
    import urllib.request

    req = urllib.request.Request(
        url,
        data=json.dumps(data).encode() if data is not None else None,
        headers={"Content-Type": "application/json"},
        method=method,
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


@app.cls(
    image=gpu_image,
    gpu=GPU,
    cpu=2.0,
    memory=8192,
    volumes={DATA: vol},
    scaledown_window=GPU_IDLE_SECONDS,
    timeout=900,
    startup_timeout=900,
    max_containers=1,
)
class Worker:
    @modal.enter()
    def start(self):
        Path("/tmp/comfy-out").mkdir(exist_ok=True)
        self.url = "http://127.0.0.1:8188"
        self.proc = subprocess.Popen(
            [
                "python", "main.py",
                "--listen", "127.0.0.1", "--port", "8188",
                "--disable-auto-launch",
                "--extra-model-paths-config", "/root/extra_model_paths.yaml",
                "--output-directory", "/tmp/comfy-out",
            ],
            cwd="/root/ComfyUI",
        )
        t0 = time.time()
        while time.time() - t0 < 600:
            if self.proc.poll() is not None:
                raise RuntimeError("ComfyUI が起動中に止まりました（ログを確認してください）")
            try:
                _http("GET", self.url + "/system_stats", timeout=5)
                print(f"ComfyUI 起動完了（{time.time() - t0:.0f} 秒）")
                return
            except Exception:
                time.sleep(1)
        raise RuntimeError("ComfyUI が起動しませんでした")

    @modal.method()
    def warm(self):
        return "ok"

    @modal.method()
    def run(self, workflow: dict) -> list:
        import urllib.error
        import urllib.parse

        # あとから追加したモデルを使うときは、ボリュームを読み直す
        ckpt = workflow.get("4", {}).get("inputs", {}).get("ckpt_name", "")
        if ckpt and not Path(CKPT_DIR, ckpt).exists():
            try:
                vol.reload()
            except Exception as e:
                print("volume reload:", e)
            if not Path(CKPT_DIR, ckpt).exists():
                raise RuntimeError(f"モデル {ckpt} が見つかりません")

        try:
            res = json.loads(_http("POST", self.url + "/prompt", {"prompt": workflow}))
        except urllib.error.HTTPError as e:
            raise RuntimeError("ComfyUI がワークフローを受け付けませんでした：" + e.read().decode()[:800])
        pid = res["prompt_id"]
        t0 = time.time()
        while time.time() - t0 < 800:
            if self.proc.poll() is not None:
                raise RuntimeError("ComfyUI が止まりました（GPU メモリ不足などの可能性）")
            hist = json.loads(_http("GET", f"{self.url}/history/{pid}"))
            if pid in hist:
                h = hist[pid]
                status = h.get("status", {})
                if status.get("status_str") == "error":
                    msgs = [m for m in status.get("messages", []) if m and m[0] == "execution_error"]
                    detail = msgs[0][1].get("exception_message", "") if msgs else ""
                    raise RuntimeError(f"ComfyUI でエラー：{detail}".strip())
                out = []
                for node in h.get("outputs", {}).values():
                    for im in node.get("images", []):
                        q = urllib.parse.urlencode({
                            "filename": im["filename"],
                            "subfolder": im.get("subfolder", ""),
                            "type": im.get("type", "output"),
                        })
                        out.append(_http("GET", f"{self.url}/view?{q}", timeout=60))
                if out:
                    print(f"生成 {time.time() - t0:.1f} 秒")
                    return out
                if status.get("completed"):
                    raise RuntimeError("画像が出力されませんでした")
            time.sleep(0.5)
        raise RuntimeError("生成がタイムアウトしました")


# ------------------------------------------------------------
# 画面：Gradio（CPU）
# ------------------------------------------------------------
ui_image = (
    modal.Image.debian_slim(python_version="3.11")
    .pip_install(f"gradio=={GRADIO_VERSION}")
    .env({
        "GRADIO_ANALYTICS_ENABLED": "False",
        "GEN_BACKEND": "modal",
        "MODAL_APP_NAME": APP_NAME,
        "MODAL_VOLUME_NAME": VOLUME_NAME,
        "OUT_DIR": f"{DATA}/outputs",
        "CHAR_FILE": f"{DATA}/characters.json",
        "APP_HOST": "0.0.0.0",
        "APP_PORT": "7860",
        "APP_SHARE": "0",
    })
    .add_local_file(HERE / "app.py", "/root/gazou_app.py")
)


@app.function(
    image=ui_image,
    volumes={DATA: vol},
    secrets=[secret],
    cpu=0.25,
    memory=1024,
    max_containers=1,          # 画面は1台だけ（履歴・キューを共有するため）
    scaledown_window=600,
    timeout=3600,
)
@modal.concurrent(max_inputs=100)
@modal.web_server(7860, startup_timeout=180)
def ui():
    import sys

    sys.path.insert(0, "/root")
    import gazou_app

    gazou_app.launch(block=False)


# ------------------------------------------------------------
# モデルのダウンロード（CPU）
# ------------------------------------------------------------
dl_image = modal.Image.debian_slim(python_version="3.11").pip_install(
    "huggingface_hub>=0.30", "hf_xet", "requests"
)

MODELS = {
    # NoobAI-XL V-Pred 1.0（Hugging Face）
    "noobai": [{"hf": "Laxhar/noobai-XL-Vpred-1.0"}],
    # WAI-illustrious v17（Civitai）→ ダメなら v16（Hugging Face のミラー）
    "wai": [
        {"civitai": "2883731", "file": "waiIllustriousSDXL_v170.safetensors"},
        {"hf": "Ba96/dss", "file": "waiIllustriousSDXL_v160.safetensors",
         "rev": "fc86417912e6b25f064969f27b610ac19e05f06f"},
    ],
}


def _tok(name):
    v = os.environ.get(name, "")
    return None if v in ("", "none") else v


def _move_in(src: Path, name: str):
    dst = Path(CKPT_DIR, name)
    dst.parent.mkdir(parents=True, exist_ok=True)
    os.replace(src, dst)
    print(f"保存しました：{dst.name}（{dst.stat().st_size / 1e9:.2f} GB）")


def _from_hf(repo, file=None, rev=None):
    import shutil

    from huggingface_hub import HfApi, hf_hub_download

    token = _tok("HF_TOKEN")
    if not file:
        info = HfApi().model_info(repo, revision=rev, files_metadata=True, token=token)
        files = [s for s in info.siblings if s.rfilename.endswith(".safetensors") and "/" not in s.rfilename]
        if not files:
            raise RuntimeError(f"{repo} に .safetensors が見つかりません")
        file = max(files, key=lambda s: s.size or 0).rfilename
    if Path(CKPT_DIR, file).exists():
        print(f"もうあります：{file}")
        return
    print(f"ダウンロード中（Hugging Face）：{repo} / {file}")
    tmp = Path(DATA, ".dl")
    p = hf_hub_download(repo, file, revision=rev, local_dir=tmp, token=token)
    _move_in(Path(p), Path(file).name)
    shutil.rmtree(tmp, ignore_errors=True)


def _from_url(urls, file=None, headers=None):
    import re

    import requests

    if file and Path(CKPT_DIR, file).exists():
        print(f"もうあります：{file}")
        return
    last = None
    for url in urls:
        try:
            with requests.get(url, headers={"User-Agent": "Mozilla/5.0", **(headers or {})},
                              stream=True, timeout=60, allow_redirects=True) as r:
                r.raise_for_status()
                cd = r.headers.get("Content-Disposition", "")
                m = re.search(r'filename\*?=(?:UTF-8\'\')?"?([^";]+)"?', cd)
                name = file or (m.group(1) if m else url.split("?")[0].rsplit("/", 1)[-1])
                name = Path(name).name or "model.safetensors"
                if not name.endswith((".safetensors", ".ckpt")):
                    name += ".safetensors"
                if Path(CKPT_DIR, name).exists():
                    print(f"もうあります：{name}")
                    return
                tmp = Path(DATA, ".dl", name + ".part")
                tmp.parent.mkdir(parents=True, exist_ok=True)
                print(f"ダウンロード中：{name}")
                with open(tmp, "wb") as f:
                    for chunk in r.iter_content(16 * 1024 * 1024):
                        f.write(chunk)
            if tmp.stat().st_size < 1e8:
                tmp.unlink()
                raise RuntimeError("ファイルが小さすぎます（キーや URL を確認してください）")
            _move_in(tmp, name)
            return
        except Exception as e:
            last = e
            print("失敗：", e)
    raise RuntimeError(f"ダウンロードできませんでした：{last}")


def _from_civitai(version_id, file=None):
    token = _tok("CIVITAI_TOKEN")
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    urls = [f"https://{h}/api/download/models/{version_id}" for h in ("civitai.com", "civitai.red")]
    _from_url(urls, file, headers)


def _get(m):
    if "civitai" in m:
        _from_civitai(m["civitai"], m.get("file"))
    elif "hf" in m:
        _from_hf(m["hf"], m.get("file"), m.get("rev"))
    else:
        _from_url([m["url"]], m.get("file"))


@app.function(image=dl_image, volumes={DATA: vol}, secrets=[secret], timeout=3 * 3600)
def download(which: str = "both", extra: str = ""):
    """which: both / noobai / wai / none、extra: Civitai のバージョンID・HF のリポジトリ名・URL"""
    names = {"both": ["noobai", "wai"], "none": []}.get(which, [which])
    errors = []
    for n in names:
        if n not in MODELS:
            errors.append(f"知らない名前：{n}")
            continue
        for i, m in enumerate(MODELS[n]):
            try:
                _get(m)
                break
            except Exception as e:
                print(f"{n}：{e}" + ("（予備で再挑戦します）" if i + 1 < len(MODELS[n]) else ""))
        else:
            errors.append(f"{n} を入れられませんでした")
        vol.commit()

    extra = extra.strip()
    if extra:
        try:
            if extra.isdigit():
                _from_civitai(extra)
            elif extra.startswith("http"):
                if "civitai." in extra and "/models/" in extra and "modelVersionId=" in extra:
                    _from_civitai(extra.split("modelVersionId=")[1].split("&")[0])
                elif "huggingface.co" in extra:
                    _from_url([extra.replace("/blob/", "/resolve/")],
                              headers={"Authorization": f"Bearer {_tok('HF_TOKEN')}"} if _tok("HF_TOKEN") else None)
                else:
                    _from_url([extra])
            elif extra.count("/") == 1:
                _from_hf(extra)
            else:
                errors.append(f"追加モデルの書き方がわかりません：{extra}")
        except Exception as e:
            errors.append(f"追加モデル：{e}")
        vol.commit()

    have = sorted(p.name for p in Path(CKPT_DIR).glob("*") if p.suffix in (".safetensors", ".ckpt"))
    print("今あるモデル：", ", ".join(have) or "（なし）")
    if errors:
        raise RuntimeError(" / ".join(errors))
    return have
