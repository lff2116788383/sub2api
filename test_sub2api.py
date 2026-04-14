import json
import sys
from urllib import error, request

API_BASE = "https://sub.tbco1a.top"
API_KEY = "把你的新APIKey填在这里"
MODEL = "gpt-5.4"
PROMPT = "请只回复：测试成功"
TIMEOUT = 60


def main() -> int:
    if not API_KEY or "把你的新APIKey填在这里" in API_KEY:
        print("错误：请先把 API_KEY 替换成你的真实 Key")
        return 1

    url = API_BASE.rstrip("/") + "/v1/chat/completions"
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "user", "content": PROMPT}
        ],
        "stream": False,
    }

    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = request.Request(
        url,
        data=data,
        method="POST",
        headers={
            "Authorization": f"Bearer {API_KEY}",
            "Content-Type": "application/json",
        },
    )

    try:
        with request.urlopen(req, timeout=TIMEOUT) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            print(f"HTTP {resp.status}")
            print(body)
            return 0
    except error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        print(f"HTTP {exc.code}")
        print(body)
        return 2
    except Exception as exc:
        print(f"请求失败：{exc}")
        return 3


if __name__ == "__main__":
    sys.exit(main())
