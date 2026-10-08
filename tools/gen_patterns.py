# 用 GPT 生地毯花色貼圖：python3 tools/gen_patterns.py [name ...]
import base64, json, os, sys, urllib.request, concurrent.futures as cf

BASE = ("A perfectly flat, straight-down orthographic scan of an entire woven rug. "
        "The rug fills the whole image edge to edge: no floor, no background, no margin, "
        "no perspective, no shadows, no fringe, no folds, evenly lit, visible fine wool pile texture. "
        "Rectangular landscape rug. Design: ")
PATTERNS = {
    "persian-red": "classic Persian Heriz-style medallion rug, deep crimson field, navy blue borders, ivory corner spandrels, intricate floral motifs",
    "blue-tabriz": "Tabriz oriental rug, indigo and sapphire field, ivory central medallion, gold and rust accents, ornate multiple borders",
    "beni-ourain": "Moroccan Beni Ourain shag rug, cream wool with thin charcoal hand-drawn diamond lattice lines",
    "kilim": "Turkish flatweave kilim, bold geometric stepped diamonds and hooks in terracotta, mustard, teal, black and off-white bands",
    "sage-modern": "minimal modern wool rug, sage green field, soft abstract cream organic blobs, thin cream border",
    "retro-check": "70s retro rug, wavy checkerboard in orange, brown, mustard and cream",
    "pink-floral": "vintage faded Oushak rug, dusty rose and salmon field, washed teal and beige floral motifs, worn antique look",
    "pixel-space": "playful kids rug, navy night sky with planets, stars and tiny rockets in flat colours",
}
OUT = os.path.join(os.path.dirname(__file__), "..", "patterns")

def gen(name):
    path = os.path.join(OUT, name + ".png")
    if os.path.exists(path):
        return name, "exists"
    body = json.dumps({"model": "gpt-image-1", "prompt": BASE + PATTERNS[name],
                       "size": "1536x1024", "quality": "high", "n": 1}).encode()
    req = urllib.request.Request("https://api.openai.com/v1/images/generations", body,
        {"Authorization": "Bearer " + os.environ["OPENAI_API_KEY"], "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=300) as r:
        data = json.load(r)
    open(path, "wb").write(base64.b64decode(data["data"][0]["b64_json"]))
    return name, "ok"

names = sys.argv[1:] or list(PATTERNS)
with cf.ThreadPoolExecutor(8) as ex:
    for f in cf.as_completed([ex.submit(gen, n) for n in names]):
        try: print(*f.result(), flush=True)
        except Exception as e: print("fail", e, flush=True)
