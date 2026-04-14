"""
格式转换器：将 CPA 格式 JSON 转换为 sub2api 格式 JSON
源格式: {account_id}.json
目标格式: sub2api-account-{timestamp}.json
"""

import json
import sys
import base64
import glob
from datetime import datetime, timezone


def decode_jwt_payload(token: str) -> dict:
    """解码 JWT token 的 payload 部分"""
    try:
        parts = token.split('.')
        if len(parts) != 3:
            return {}
        payload = parts[1]
        # 添加 padding
        padding = 4 - len(payload) % 4
        if padding != 4:
            payload += '=' * padding
        decoded = base64.urlsafe_b64decode(payload)
        return json.loads(decoded)
    except Exception:
        return {}


def parse_expired_time(expired_str: str) -> int:
    """解析过期时间字符串为 Unix 时间戳"""
    try:
        # 处理带时区的 ISO 格式
        if '+' in expired_str:
            dt = datetime.fromisoformat(expired_str)
        else:
            dt = datetime.fromisoformat(expired_str.replace('Z', '+00:00'))
        return int(dt.timestamp())
    except Exception:
        return 0


def convert_cpa_to_sub2api(source_data: dict, index: int = 1) -> dict:
    """
    将 CPA 格式转换为 sub2api 格式

    Args:
        source_data: 源 JSON 数据
        index: 账号序号，用于生成名称

    Returns:
        转换后的 sub2api 格式数据
    """
    # 从 access_token 解析信息
    jwt_payload = decode_jwt_payload(source_data.get('access_token', ''))
    auth_info = jwt_payload.get('https://api.openai.com/auth', {})

    # 计算 expires_at
    expires_at = parse_expired_time(source_data.get('expired', ''))
    if expires_at == 0:
        expires_at = jwt_payload.get('exp', 0)

    # 获取 chatgpt_user_id
    chatgpt_user_id = auth_info.get('chatgpt_user_id', '')

    # 获取 organization_id (从 id_token 解析)
    id_token_payload = decode_jwt_payload(source_data.get('id_token', ''))
    id_token_auth = id_token_payload.get('https://api.openai.com/auth', {})
    organizations = id_token_auth.get('organizations', [])
    organization_id = organizations[0].get('id', '') if organizations else ''

    # 生成账号名称
    account_type = source_data.get('type', 'unknown')
    name = f"{account_type}-普号-{index:04d}"

    # 构建目标格式
    account = {
        "name": name,
        "platform": "openai",
        "type": "oauth",
        "credentials": {
            "access_token": source_data.get('access_token', ''),
            "chatgpt_account_id": source_data.get('account_id', ''),
            "chatgpt_user_id": chatgpt_user_id,
            "expires_at": expires_at,
            "expires_in": 864000,  # 默认 10 天
            "organization_id": organization_id,
            "refresh_token": source_data.get('refresh_token', '')
        },
        "extra": {
            "email": source_data.get('email', '')
        },
        "concurrency": 10,
        "priority": 1,
        "rate_multiplier": 1,
        "auto_pause_on_expired": True
    }

    return account


def convert_files(input_files: list[str], output_file: str = None) -> str:
    """
    转换多个 CPA 格式文件为单个 sub2api 格式文件

    Args:
        input_files: 输入文件路径列表
        output_file: 输出文件路径（可选，默认自动生成）

    Returns:
        输出文件路径
    """
    accounts = []

    for idx, input_file in enumerate(input_files, start=1):
        with open(input_file, 'r', encoding='utf-8') as f:
            source_data = json.load(f)

        account = convert_cpa_to_sub2api(source_data, idx)
        accounts.append(account)

    # 生成输出数据
    now = datetime.now(timezone.utc)
    result = {
        "exported_at": now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        "proxies": [],
        "accounts": accounts
    }

    # 生成输出文件名
    if output_file is None:
        timestamp = now.strftime('%Y%m%d%H%M%S')
        output_file = f"sub2api-account-{timestamp}.json"

    with open(output_file, 'w', encoding='utf-8') as f:
        json.dump(result, f, ensure_ascii=False, indent=2)

    return output_file


def convert_directory(directory: str, type_filter: str = None, output_file: str = None) -> str:
    """
    批量转换目录下的所有 JSON 文件

    Args:
        directory: 目录路径
        type_filter: 只转换指定 type 的文件 (如 "codex")
        output_file: 输出文件路径

    Returns:
        输出文件路径
    """
    pattern = f"{directory}/*.json"
    all_files = glob.glob(pattern)

    # 过滤文件
    valid_files = []
    for filepath in all_files:
        try:
            with open(filepath, 'r', encoding='utf-8') as f:
                data = json.load(f)
            # 检查是否符合源格式 (有 access_token 和 account_id)
            if 'access_token' not in data or 'account_id' not in data:
                continue
            # 检查 type 过滤
            if type_filter and data.get('type') != type_filter:
                continue
            valid_files.append(filepath)
        except Exception:
            continue

    if not valid_files:
        print(f"错误: 在 {directory} 中未找到符合条件的文件")
        sys.exit(1)

    # 按文件名排序保证顺序一致
    valid_files.sort()

    print(f"找到 {len(valid_files)} 个 {type_filter or '有效'} 类型的文件")

    return convert_files(valid_files, output_file)


def main():
    if len(sys.argv) < 2:
        print("用法:")
        print("  python converter.py <input_file.json> [input_file2.json ...] [-o output.json]")
        print("  python converter.py -d <directory> [-t type] [-o output.json]")
        print()
        print("示例:")
        print("  python converter.py 1e4fed1e-5ff5-47fb-bada-b6007bedd9dd.json")
        print("  python converter.py *.json -o output.json")
        print("  python converter.py -d /path/to/auth -t codex -o codex-accounts.json")
        sys.exit(1)

    # 解析参数
    input_files = []
    output_file = None
    directory = None
    type_filter = None

    i = 1
    while i < len(sys.argv):
        arg = sys.argv[i]
        if arg == '-o' and i + 1 < len(sys.argv):
            output_file = sys.argv[i + 1]
            i += 2
        elif arg == '-d' and i + 1 < len(sys.argv):
            directory = sys.argv[i + 1]
            i += 2
        elif arg == '-t' and i + 1 < len(sys.argv):
            type_filter = sys.argv[i + 1]
            i += 2
        else:
            # 检查是否为有效的 JSON 文件（排除已有的 sub2api 格式文件）
            if arg.endswith('.json') and not arg.startswith('sub2api-'):
                input_files.append(arg)
            i += 1

    # 目录模式
    if directory:
        output_path = convert_directory(directory, type_filter, output_file)
        print(f"转换完成! 输出文件: {output_path}")
        return

    # 文件模式
    if not input_files:
        print("错误: 未找到有效的输入文件")
        sys.exit(1)

    print(f"正在转换 {len(input_files)} 个文件...")

    output_path = convert_files(input_files, output_file)
    print(f"转换完成! 输出文件: {output_path}")


if __name__ == '__main__':
    main()