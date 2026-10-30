"""
画像生成アプリ（ComfyUI フロントエンド）クラウドGPU版
- 同じマシンで ComfyUI を http://127.0.0.1:8188 で起動しておく
- iPhone などから、パスワード付きで操作する
環境変数: APP_USER / APP_PASSWORD / APP_HOST / APP_PORT / APP_SHARE / OUT_DIR / CHAR_FILE
          GEN_BACKEND（comfy=同じマシンの ComfyUI / modal=Modal の GPU を呼ぶ）
"""
import json
import os
import random
import re
import time
import unicodedata
import urllib.parse
import urllib.request
import uuid
from datetime import datetime
from pathlib import Path

import gradio as gr

COMFY_URL = os.environ.get("COMFY_URL", "http://127.0.0.1:8188")
BACKEND = os.environ.get("GEN_BACKEND", "comfy")
MODAL_APP = os.environ.get("MODAL_APP_NAME", "gazougen")
MODAL_VOLUME = os.environ.get("MODAL_VOLUME_NAME", "gazougen-data")
BASE_DIR = Path(__file__).parent
# 保存先（Modal では永続ボリューム /data に置く）
CHAR_FILE = Path(os.environ.get("CHAR_FILE", BASE_DIR / "characters.json"))
OUT_DIR = Path(os.environ.get("OUT_DIR", BASE_DIR / "outputs"))
OUT_DIR.mkdir(parents=True, exist_ok=True)
CHAR_FILE.parent.mkdir(parents=True, exist_ok=True)

# モデルごとの推奨設定（ファイル名で自動判定）
PROFILES = {
    "noobai": {
        "label": "NoobAI-XL",
        "quality": "masterpiece, best quality, newest, absurdres, highres",
        "quality_first": True,
        "neg": ("worst quality, old, early, low quality, lowres, signature, username, logo, "
                "bad hands, mutated hands, bad anatomy, extra digits, fewer digits, jpeg artifacts, blurry"),
        "sampler": "euler", "scheduler": "normal", "cfg": 4.5, "steps": 30,
    },
    "wai": {
        "label": "WAI-illustrious",
        # WAI はプロンプトの後ろに品質タグを付けるのが推奨
        "quality": "masterpiece, best quality, amazing quality",
        "quality_first": False,
        "neg": "bad quality, worst quality, worst detail, sketch, censor, lowres, bad hands, bad anatomy",
        "sampler": "euler_ancestral", "scheduler": "normal", "cfg": 6.0, "steps": 28,
    },
    "default": {
        "label": "その他（Illustrious 系の標準設定）",
        "quality": "masterpiece, best quality, amazing quality, very aesthetic, absurdres",
        "quality_first": True,
        "neg": ("lowres, bad anatomy, bad hands, missing fingers, extra digits, fewer digits, "
                "worst quality, low quality, jpeg artifacts, blurry, watermark, signature, text"),
        "sampler": "euler_ancestral", "scheduler": "normal", "cfg": 5.5, "steps": 28,
    },
}
NEG_SFW = "nsfw, explicit, nude"  # R18 オフのときだけ付く
NEG_R18 = "child, loli, shota, toddler, aged down"  # R18 オンのときに必ず付く（幼く描かれるのを防ぐ）


def profile_for(ckpt: str) -> dict:
    n = (ckpt or "").lower()
    if "noob" in n:
        return PROFILES["noobai"]
    if "wai" in n:
        return PROFILES["wai"]
    return PROFILES["default"]

SIZES = {
    "正方形 1024x1024": (1024, 1024),
    "縦長 832x1216": (832, 1216),
    "縦長 896x1152": (896, 1152),
    "横長 1216x832": (1216, 832),
    "横長 1152x896": (1152, 896),
}
# V-Pred モデルは euler が推奨（他は崩れやすい）
SAMPLERS = ["euler", "euler_ancestral", "dpmpp_2m", "dpmpp_2m_sde", "dpmpp_sde"]
SCHEDULERS = ["normal", "karras", "exponential", "sgm_uniform"]

# ------------------------------------------------------------
# 年齢チェック（R18 オン時のみ）
# 未成年を明確に指す語・年齢指定が含まれていたら生成しない
# ------------------------------------------------------------
_BLOCK_JA = [
    "子供", "子ども", "こども", "幼女", "幼児", "幼稚園", "児童", "ロリ", "ショタ",
    "小学生", "中学生", "高校生", "女子高生", "男子高校生", "未成年", "赤ちゃん", "乳児",
]
_BLOCK_EN = [
    "child", "children", "kid", "kids", "toddler", "infant", "baby", "loli", "lolicon",
    "shota", "shotacon", "underage", "preteen", "pre-teen", "little girl", "little boy",
    "elementary school", "middle school", "junior high", "high school student",
    "grade schooler",
]
_EN_RE = re.compile(
    r"(?<![a-z])(" + "|".join(re.escape(t) for t in _BLOCK_EN) + r")(?![a-z])"
)
_AGE_RE = re.compile(r"(\d{1,2})\s*(?:years?\s*old|yo|y/o|歳|才|さい)")


def _normalize(text: str) -> str:
    t = unicodedata.normalize("NFKC", text).lower()
    return t.replace("_", " ")


def age_check(text: str):
    """問題なければ None、引っかかったら理由の文字列を返す"""
    t = _normalize(text)
    for w in _BLOCK_JA:
        if w in t:
            return f"未成年を指す語（{w}）が含まれています"
    m = _EN_RE.search(t)
    if m:
        return f"未成年を指す語（{m.group(1)}）が含まれています"
    for m in _AGE_RE.finditer(t):
        if int(m.group(1)) < 18:
            return f"18歳未満の年齢指定（{m.group(0)}）が含まれています"
    return None


# ------------------------------------------------------------
# ComfyUI API
# ------------------------------------------------------------
def _get(path: str):
    with urllib.request.urlopen(COMFY_URL + path, timeout=10) as r:
        return r.read()


def _post(path: str, data: dict):
    req = urllib.request.Request(
        COMFY_URL + path,
        data=json.dumps(data).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())


def list_checkpoints():
    if BACKEND == "modal":
        # Modal のボリューム（/checkpoints）にあるモデルを直接見る（GPU は起動しない）
        try:
            import modal
            vol = modal.Volume.from_name(MODAL_VOLUME)
            names = [Path(e.path).name for e in vol.listdir("/checkpoints")]
            return sorted(n for n in names if n.endswith((".safetensors", ".ckpt")))
        except Exception:
            return []
    try:
        info = json.loads(_get("/object_info/CheckpointLoaderSimple"))
        return info["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"][0]
    except Exception:
        return []


def is_vpred(ckpt: str) -> bool:
    return "vpred" in ckpt.lower().replace("-", "").replace("_", "")


def build_workflow(ckpt, pos, neg, w, h, steps, cfg, sampler, scheduler, seed):
    wf = {
        "4": {"class_type": "CheckpointLoaderSimple", "inputs": {"ckpt_name": ckpt}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"text": pos, "clip": ["4", 1]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"text": neg, "clip": ["4", 1]}},
        "5": {"class_type": "EmptyLatentImage",
              "inputs": {"width": w, "height": h, "batch_size": 1}},
        "3": {"class_type": "KSampler", "inputs": {
            "seed": seed, "steps": steps, "cfg": cfg,
            "sampler_name": sampler, "scheduler": scheduler, "denoise": 1.0,
            "model": ["4", 0], "positive": ["6", 0], "negative": ["7", 0],
            "latent_image": ["5", 0]}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["4", 2]}},
        "9": {"class_type": "SaveImage",
              "inputs": {"filename_prefix": "gazouapp", "images": ["8", 0]}},
    }
    if is_vpred(ckpt):
        # V-Pred モデル（NoobAI-XL V-Pred など）は、v_prediction + zSNR で動かす
        wf["10"] = {"class_type": "ModelSamplingDiscrete",
                    "inputs": {"sampling": "v_prediction", "zsnr": True, "model": ["4", 0]}}
        wf["3"]["inputs"]["model"] = ["10", 0]
    return wf


def _modal_worker():
    import modal
    return modal.Cls.from_name(MODAL_APP, "Worker")()


def warm_gpu():
    """画面を開いたら、GPU を先に起動しておく（生成ボタンを押すころには準備ができている）"""
    if BACKEND == "modal":
        try:
            _modal_worker().warm.spawn()
        except Exception:
            pass


def run_job(workflow):
    """1枚分のワークフローを実行して、PNG のバイト列のリストを返す"""
    if BACKEND == "modal":
        return _modal_worker().run.remote(workflow)
    return run_comfy(workflow)


def run_comfy(workflow, timeout=600):
    res = _post("/prompt", {"prompt": workflow, "client_id": str(uuid.uuid4())})
    pid = res["prompt_id"]
    start = time.time()
    while time.time() - start < timeout:
        hist = json.loads(_get(f"/history/{pid}"))
        if pid in hist:
            imgs = hist[pid]["outputs"]["9"]["images"]
            results = []
            for im in imgs:
                q = urllib.parse.urlencode({
                    "filename": im["filename"],
                    "subfolder": im.get("subfolder", ""),
                    "type": im.get("type", "output"),
                })
                results.append(_get(f"/view?{q}"))
            return results
        time.sleep(1)
    raise TimeoutError("生成がタイムアウトしました")


# ------------------------------------------------------------
# キャラクター設定
# ------------------------------------------------------------
def load_chars() -> dict:
    if CHAR_FILE.exists():
        return json.loads(CHAR_FILE.read_text(encoding="utf-8"))
    return {}


def save_chars(chars: dict):
    CHAR_FILE.write_text(json.dumps(chars, ensure_ascii=False, indent=2), encoding="utf-8")


def char_names():
    return ["（なし）"] + sorted(load_chars().keys())


# ------------------------------------------------------------
# 生成処理
# ------------------------------------------------------------
def generate(ckpt, char_name, prompt, negative, r18, size, steps, cfg,
             sampler, scheduler, seed, count):
    if not ckpt:
        if BACKEND == "modal":
            raise gr.Error("モデルが選ばれていません。モデルのダウンロードが終わったら 🔄 を押してください。")
        raise gr.Error("モデルが選ばれていません。ComfyUI が起動しているか確認してください。")

    chars = load_chars()
    char = chars.get(char_name) if char_name and char_name != "（なし）" else None

    prof = profile_for(ckpt)
    pos_parts = []
    if char and char.get("tags"):
        pos_parts.append(char["tags"])
    if prompt.strip():
        pos_parts.append(prompt.strip())
    if prof["quality_first"]:
        pos_parts.insert(0, prof["quality"])
    else:
        pos_parts.append(prof["quality"])
    pos = ", ".join(pos_parts)

    neg_parts = [prof["neg"]]
    neg_parts.append(NEG_R18 if r18 else NEG_SFW)
    if char and char.get("negative"):
        neg_parts.append(char["negative"])
    if negative.strip():
        neg_parts.append(negative.strip())
    neg = ", ".join(neg_parts)

    if r18:
        reason = age_check(pos)
        if reason:
            raise gr.Error(f"R18 モードでは生成できません：{reason}")

    w, h = SIZES[size]
    base_seed = int(seed) if int(seed) >= 0 else random.randint(0, 2**32 - 1)
    paths = []
    last = 0.0
    n = int(count)
    wait_note = "（GPU が止まっていたときは、起動に 1〜2 分かかります）" if BACKEND == "modal" else ""
    for i in range(n):
        s = base_seed + i
        yield paths, f"生成中… {i + 1}/{n} 枚目{wait_note if i == 0 else ''}"
        wf = build_workflow(ckpt, pos, neg, w, h, int(steps), float(cfg), sampler, scheduler, s)
        t0 = time.time()
        try:
            images = run_job(wf)
        except urllib.error.URLError:
            raise gr.Error(f"ComfyUI（{COMFY_URL}）に接続できません。先に起動してください。")
        except gr.Error:
            raise
        except Exception as e:
            raise gr.Error(f"生成に失敗しました：{e}")
        for data in images:
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            p = OUT_DIR / f"{stamp}_{s}.png"
            p.write_bytes(data)
            meta = {"positive": pos, "negative": neg, "seed": s, "steps": steps, "cfg": cfg,
                    "sampler": sampler, "scheduler": scheduler, "size": [w, h],
                    "model": ckpt, "character": char_name, "r18": r18}
            p.with_suffix(".json").write_text(json.dumps(meta, ensure_ascii=False, indent=2),
                                              encoding="utf-8")
            paths.append(str(p))
        last = time.time() - t0
    yield paths, f"完了：{n} 枚（seed: {base_seed}、最後の1枚 {last:.0f} 秒）"


def history(limit=60):
    files = sorted(OUT_DIR.glob("*.png"), key=lambda p: p.stat().st_mtime, reverse=True)
    return [str(p) for p in files[:limit]]


def save_char(name, tags, negative):
    name = name.strip()
    if not name:
        raise gr.Error("キャラ名を入れてください")
    chars = load_chars()
    chars[name] = {"tags": tags.strip(), "negative": negative.strip()}
    save_chars(chars)
    return gr.update(choices=char_names(), value=name), gr.update(choices=char_names()), f"「{name}」を保存しました"


def load_char(name):
    c = load_chars().get(name, {})
    return name if c else "", c.get("tags", ""), c.get("negative", "")


def delete_char(name):
    chars = load_chars()
    if name in chars:
        del chars[name]
        save_chars(chars)
    return gr.update(choices=char_names(), value="（なし）"), gr.update(choices=char_names(), value="（なし）"), f"「{name}」を削除しました"


def refresh_models():
    ck = list_checkpoints()
    return gr.update(choices=ck, value=ck[0] if ck else None)


def apply_profile(ckpt):
    """モデルを切り替えたら、そのモデルの推奨設定に合わせる"""
    p = profile_for(ckpt)
    note = (f"推奨設定（{p['label']}）：サンプラー {p['sampler']}・CFG {p['cfg']}・"
            f"ステップ {p['steps']}" + ("・V-Pred で実行" if ckpt and is_vpred(ckpt) else ""))
    return (gr.update(value=p["sampler"]), gr.update(value=p["scheduler"]),
            gr.update(value=p["cfg"]), gr.update(value=p["steps"]), note)


# ------------------------------------------------------------
# UI
# ------------------------------------------------------------
def build_ui():
    ck = list_checkpoints()
    with gr.Blocks(title="画像生成") as demo:
        gr.Markdown("## 画像生成")
        with gr.Tab("生成"):
            with gr.Row():
                with gr.Column(scale=1):
                    with gr.Row():
                        ckpt = gr.Dropdown(ck, value=ck[0] if ck else None, label="モデル", scale=4)
                        ref = gr.Button("🔄", scale=1)
                    char = gr.Dropdown(char_names(), value="（なし）", label="キャラクター")
                    prompt = gr.Textbox(label="プロンプト（ポーズ・服・背景など）", lines=4)
                    negative = gr.Textbox(label="追加のネガティブ", lines=2)
                    r18 = gr.Checkbox(label="R18 モード", value=False)
                    prof_note = gr.Markdown()
                    size = gr.Dropdown(list(SIZES), value="縦長 832x1216", label="サイズ")
                    with gr.Accordion("詳細設定", open=False):
                        steps = gr.Slider(10, 60, value=30, step=1, label="ステップ数（推奨 28〜35）")
                        cfg = gr.Slider(1, 12, value=4.5, step=0.5, label="CFG（V-Pred は 4〜5 推奨）")
                        sampler = gr.Dropdown(SAMPLERS, value="euler", label="サンプラー（V-Pred は euler 推奨）")
                        scheduler = gr.Dropdown(SCHEDULERS, value="normal", label="スケジューラ")
                        seed = gr.Number(value=-1, label="シード（-1でランダム）", precision=0)
                        count = gr.Slider(1, 8, value=1, step=1, label="枚数")
                    go = gr.Button("生成", variant="primary")
                with gr.Column(scale=1):
                    out = gr.Gallery(label="結果", columns=2, height=640)
                    info = gr.Markdown()
            ref.click(refresh_models, outputs=ckpt)
            ckpt.change(apply_profile, ckpt, [sampler, scheduler, cfg, steps, prof_note])
            demo.load(apply_profile, ckpt, [sampler, scheduler, cfg, steps, prof_note])
            demo.load(warm_gpu)
            go.click(generate,
                     [ckpt, char, prompt, negative, r18, size, steps, cfg, sampler, scheduler, seed, count],
                     [out, info])

        with gr.Tab("キャラクター"):
            gr.Markdown("髪型・目の色・服装など、毎回同じにしたい見た目のタグを保存できます。")
            pick = gr.Dropdown(char_names(), value="（なし）", label="既存キャラを読み込む")
            cname = gr.Textbox(label="キャラ名")
            ctags = gr.Textbox(label="見た目タグ（例: 1girl, long hair, silver hair, red eyes）", lines=3)
            cneg = gr.Textbox(label="このキャラ用ネガティブ", lines=2)
            with gr.Row():
                csave = gr.Button("保存", variant="primary")
                cdel = gr.Button("削除")
            cmsg = gr.Markdown()
            pick.change(load_char, pick, [cname, ctags, cneg])
            csave.click(save_char, [cname, ctags, cneg], [char, pick, cmsg])
            cdel.click(delete_char, cname, [char, pick, cmsg])

        with gr.Tab("履歴"):
            hbtn = gr.Button("更新")
            hgal = gr.Gallery(columns=4, height=720)
            hbtn.click(history, outputs=hgal)
            demo.load(history, outputs=hgal)
    return demo


def launch(block=True):
    user = os.environ.get("APP_USER", "me") or "me"
    password = os.environ.get("APP_PASSWORD", "")
    if len(password) < 8:
        raise SystemExit("APP_PASSWORD を8文字以上で設定してください（公開リンクを守るため）")
    host = os.environ.get("APP_HOST", "127.0.0.1")
    port = int(os.environ.get("APP_PORT", "7860"))
    share = os.environ.get("APP_SHARE", "1") == "1"   # Modal では 0（Modal の URL を使う）
    build_ui().queue(default_concurrency_limit=1).launch(
        server_name=host, server_port=port, share=share, auth=(user, password),
        allowed_paths=[str(OUT_DIR)], prevent_thread_lock=not block)


if __name__ == "__main__":
    launch()
