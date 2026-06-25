#!/usr/bin/env python3
"""
日程事件自然语言解析器
解析中文自然语言描述，提取：标题、时间、地点、备注、日历归属

用法:
    python3 parse_event.py "明天下午3点在301开会讨论Q3计划"
    python3 parse_event.py --username myname "周六晚上7点带爸妈去海底捞吃饭"
    python3 parse_event.py --json "下周二上午9点去医院体检，记得空腹"

输出:
    JSON 结构体，包含 title, start_time, end_time, location, description, calendar, confidence
"""

import sys
import json
import re
from datetime import datetime, timedelta, date


# ═══════════════════════════════════════════════════════════════════════════════
# 时间解析
# ═══════════════════════════════════════════════════════════════════════════════

WEEKDAY_MAP = {
    "周一": 0, "周一": 0, "星期二": 1, "周二": 1,
    "星期三": 2, "周三": 2, "星期四": 3, "周四": 3,
    "星期五": 4, "周五": 4, "星期六": 5, "周六": 5,
    "星期日": 6, "周日": 6, "星期天": 6,
}

TIME_PATTERNS = [
    # "明天下午3点"  "后天上午9点半"
    (r'(今天|明天|后天|大后天)\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', 'relative_day'),
    # "下周二上午9点"  "下下周三下午2点"
    (r'(下下|下)?\s*(周[一二三四五六日天]|星期[一二三四五六日天])\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', 'weekday'),
    # "6月25日下午3点"
    (r'(\d{1,2})月(\d{1,2})[日号]?\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', 'absolute_date'),
    # "下午3点" (没有日期，默认今天)
    (r'^(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', 'time_only'),
    # "半小时后" "1小时后" "2小时后"
    (r'(\d+)\s*(个)?(小时|分钟|半小时)后', 'relative_offset'),
    # "晚上7点" (句中，不是开头)
    (r'(上午|下午|晚上|中午|早上|傍晚|凌晨)\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', 'time_period'),
]

LOCATION_PATTERNS = [
    # "在XXX" 后面跟地点（扩展：数字+地名也匹配，如"在301"）
    r'在([\u4e00-\u9fa5a-zA-Z0-9]{1,20}?(?:会议室|房间|餐厅|酒店|医院|咖啡厅|咖啡馆|办公室|大厦|广场|中心|公园|学校|银行|机场|车站|健身房|游泳馆|图书馆|厅|室|楼))',
    # "去XXX" 
    r'去([\u4e00-\u9fa5a-zA-Z0-9]{1,20}?(?:餐厅|酒店|医院|咖啡厅|咖啡馆|办公室|大厦|广场|中心|公园|学校|银行|机场|车站|健身房|游泳馆|图书馆|电影院|商场|超市|厅|室))',
    # "到XXX"
    r'到([\u4e00-\u9fa5a-zA-Z0-9]{1,20}?(?:会议室|房间|餐厅|酒店|医院|咖啡厅|咖啡馆|办公室|大厦|广场|中心|公园|学校|银行|机场|车站|健身房|游泳馆|图书馆|厅|室|楼))',
    # "@XXX" 或 "#XXX"
    r'[@#]([\u4e00-\u9fa5a-zA-Z0-9]{1,20})',
    # "地点XXX" "位置XXX"
    r'(?:地点|位置|地址)[：:]\s*([\u4e00-\u9fa5a-zA-Z0-9\s]{1,30})',
    # 数字+地名：301会议室、3楼、2号厅
    r'(\d+[号#]?\s*(?:楼|层|室|厅|会议室|房间|办公室|餐厅|咖啡厅))',
]

CALENDAR_HINTS = {
    "工作": ["开会", "会议", "汇报", "周报", "项目", "需求", "评审", "上线", "面试",
             "出差", "培训", "讨论", "方案", "客户", "合同", "预算", "KPI", "OKR",
             "团队", "部门", "周会", "站会", "复盘", "迭代", "发布"],
    "家庭": ["爸妈", "妈妈", "爸爸", "孩子", "老婆", "老公", "家人", "回家",
             "聚餐", "吃饭", "做饭", "买菜", "打扫", "装修", "搬家"],
    "个人": ["健身", "跑步", "游泳", "瑜伽", "体检", "看书", "学习", "课程",
             "理发", "洗牙", "电影", "游戏", "旅行", "旅游"],
    "健康": ["体检", "看病", "复查", "牙医", "中医", "挂号", "药", "疫苗",
             "跑步", "健身", "游泳", "瑜伽", "冥想"],
    "生日": ["生日", "纪念日", "周年"],
}


def parse_relative_day(text):
    """解析 今天/明天/后天 + 时间段 + 时间"""
    today = date.today()
    day_offset = {"今天": 0, "明天": 1, "后天": 2, "大后天": 3}
    period_offset = {"凌晨": 0, "早上": 7, "上午": 9, "中午": 12, "下午": 14, "傍晚": 17, "晚上": 19}

    for m in re.finditer(r'(今天|明天|后天|大后天)\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', text):
        day_str = m.group(1)
        period = m.group(2) or ""
        hour = int(m.group(3))
        half = m.group(4) == "半"
        minute_str = m.group(5)

        # 调整小时
        if period:
            base = period_offset.get(period, 0)
            if period in ("上午", "早上") and hour == 12:
                hour = 0
            elif period in ("下午", "晚上") and hour != 12:
                hour += 12
        else:
            base = 0

        if half:
            minute = 30
        elif minute_str:
            minute = int(minute_str)
        else:
            minute = 0

        target_date = today + timedelta(days=day_offset[day_str])
        dt = datetime(target_date.year, target_date.month, target_date.day, hour, minute)
        return dt

    return None


def parse_weekday(text):
    """解析 下周二/周三 上午9点"""
    today = date.today()
    for m in re.finditer(r'(下下|下)?\s*(周[一二三四五六日天]|星期[一二三四五六日天])\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', text):
        prefix = m.group(1) or ""
        weekday_str = m.group(2)
        period = m.group(3) or ""
        hour = int(m.group(4))
        half = m.group(5) == "半"
        minute_str = m.group(6)

        target_weekday = WEEKDAY_MAP.get(weekday_str, 0)
        current_weekday = today.weekday()

        # 计算目标日期
        if "下下" in prefix:
            days_ahead = (target_weekday - current_weekday) % 7 + 7
        elif "下" in prefix:
            days_ahead = (target_weekday - current_weekday) % 7 + 7
        else:
            days_ahead = (target_weekday - current_weekday) % 7
            if days_ahead == 0:
                days_ahead = 0  # 就是今天

        period_offset = {"凌晨": 0, "早上": 7, "上午": 9, "中午": 12, "下午": 14, "傍晚": 17, "晚上": 19}
        if period in ("下午", "晚上") and hour != 12:
            hour += 12
        elif period in ("上午", "早上") and hour == 12:
            hour = 0

        if half:
            minute = 30
        elif minute_str:
            minute = int(minute_str)
        else:
            minute = 0

        target_date = today + timedelta(days=days_ahead)
        dt = datetime(target_date.year, target_date.month, target_date.day, hour, minute)
        return dt

    return None


def parse_absolute_date(text):
    """解析 6月25日下午3点"""
    for m in re.finditer(r'(\d{1,2})月(\d{1,2})[日号]?\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', text):
        month = int(m.group(1))
        day = int(m.group(2))
        period = m.group(3) or ""
        hour = int(m.group(4))
        half = m.group(5) == "半"
        minute_str = m.group(6)

        if period in ("下午", "晚上") and hour != 12:
            hour += 12
        elif period in ("上午", "早上") and hour == 12:
            hour = 0

        if half:
            minute = 30
        elif minute_str:
            minute = int(minute_str)
        else:
            minute = 0

        year = date.today().year
        dt = datetime(year, month, day, hour, minute)
        return dt

    return None


def parse_relative_offset(text):
    """解析 半小时后/2小时后/10分钟后"""
    # 先匹配带数字的：2小时后、10分钟后
    for m in re.finditer(r'(\d+)\s*(个)?(小时|分钟)后', text):
        num = int(m.group(1))
        unit = m.group(3)
        now = datetime.now()
        if unit == "小时":
            return now + timedelta(hours=num)
        elif unit == "分钟":
            return now + timedelta(minutes=num)

    # 匹配"半小时后"
    if re.search(r'半小时后', text):
        return datetime.now() + timedelta(minutes=30)

    # 匹配"一小时后" "一个小时后"
    m = re.search(r'一(个)?小时后', text)
    if m:
        return datetime.now() + timedelta(hours=1)

    return None


def parse_time_period_inline(text):
    """解析句中的时间段表达，如"晚上8点和朋友..." → 今天/明天对应时间"""
    period_offset = {"凌晨": 0, "早上": 7, "上午": 9, "中午": 12, "下午": 14, "傍晚": 17, "晚上": 19}

    for m in re.finditer(r'(上午|下午|晚上|中午|早上|傍晚|凌晨)\s*(\d{1,2})\s*点\s*(半|(\d{1,2})分)?', text):
        period = m.group(1)
        hour = int(m.group(2))
        half = m.group(3) == "半"
        minute_str = m.group(4)

        if period in ("下午", "晚上") and hour != 12:
            hour += 12
        elif period in ("上午", "早上") and hour == 12:
            hour = 0

        if half:
            minute = 30
        elif minute_str:
            minute = int(minute_str)
        else:
            minute = 0

        now = datetime.now()
        target_dt = datetime(now.year, now.month, now.day, hour, minute)

        # 如果时间已过，推到明天
        if target_dt <= now:
            target_dt += timedelta(days=1)

        return target_dt

    return None


def parse_time(text):
    """主时间解析函数，尝试所有模式"""
    now = datetime.now()

    # 尝试相对日期模式（明天、后天 + 时间）
    dt = parse_relative_day(text)
    if dt:
        return dt, "relative_day"

    # 尝试星期模式（下周二 + 时间）
    dt = parse_weekday(text)
    if dt:
        return dt, "weekday"

    # 尝试绝对日期（6月25日 + 时间）
    dt = parse_absolute_date(text)
    if dt:
        return dt, "absolute_date"

    # 尝试相对偏移（半小时后）
    dt = parse_relative_offset(text)
    if dt:
        return dt, "relative_offset"

    # 尝试句中时间段（"晚上8点..."）→ 默认为今天
    dt = parse_time_period_inline(text)
    if dt:
        return dt, "time_period_inline"

    # 兜底：默认明天上午9点
    tomorrow = now + timedelta(days=1)
    default_dt = datetime(tomorrow.year, tomorrow.month, tomorrow.day, 9, 0)
    return default_dt, "default"


def parse_location(text):
    """解析地点"""
    for pattern in LOCATION_PATTERNS:
        m = re.search(pattern, text)
        if m:
            return m.group(1).strip()
    return ""


def parse_title(text):
    """解析标题：提取核心事项"""
    # 移除时间表达
    cleaned = text
    cleaned = re.sub(r'(今天|明天|后天|大后天)\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*\d{1,2}\s*点\s*(半|\d{1,2}分)?', '', cleaned)
    cleaned = re.sub(r'(下下|下)?\s*(周[一二三四五六日天]|星期[一二三四五六日天])\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*\d{1,2}\s*点\s*(半|\d{1,2}分)?', '', cleaned)
    cleaned = re.sub(r'\d{1,2}月\d{1,2}[日号]?\s*(上午|下午|晚上|中午|早上|傍晚|凌晨)?\s*\d{1,2}\s*点\s*(半|\d{1,2}分)?', '', cleaned)
    cleaned = re.sub(r'\d+\s*(个)?(小时|分钟)后', '', cleaned)
    cleaned = re.sub(r'半小时后', '', cleaned)
    cleaned = re.sub(r'一小时后', '', cleaned)
    # 句中时间：上午/下午/晚上 X点
    cleaned = re.sub(r'(上午|下午|晚上|中午|早上|傍晚|凌晨)\s*\d{1,2}\s*点\s*(半|\d{1,2}分)?', '', cleaned)

    # 移除地点表达（在XXX、去XXX、到XXX）
    for pattern in LOCATION_PATTERNS:
        cleaned = re.sub(pattern, '', cleaned)
    # 额外清理残留
    cleaned = re.sub(r'(在|去|到)\s*(医院|餐厅|酒店|咖啡厅|办公室|学校|星巴克|海底捞)', '', cleaned)
    cleaned = re.sub(r'(在|去|到)\s*\d+(号|楼|层|室|厅|会议室|房间)', '', cleaned)

    # 移除常见前缀
    cleaned = re.sub(r'^(记得|别忘了|帮我|请|要|和|跟)\s*', '', cleaned)
    # 移除常见连接词
    cleaned = re.sub(r'^(在|去|到)\s*', '', cleaned)
    cleaned = re.sub(r'\s*(，|,|。|！|!|~|～)\s*$', '', cleaned)
    cleaned = re.sub(r'\s+', '', cleaned)

    if not cleaned or len(cleaned) < 2:
        return "日程"

    # 截取合理长度
    if len(cleaned) > 30:
        cleaned = cleaned[:30]

    return cleaned


def parse_description(text, location=""):
    """提取备注"""
    notes = text

    # 如果有地点且出现在原文中，保留
    if location and location in notes:
        pass

    # 常见备注关键词后的内容
    m = re.search(r'(备注|注意|PS|p\.s\.)[：:]\s*(.+)', text, re.IGNORECASE)
    if m:
        return m.group(2).strip()

    # 提取 "记得XXX" "别忘了XXX"
    m = re.search(r'(记得|别忘了)(.+)', text)
    if m:
        return m.group(2).strip()

    return ""


def parse_calendar(text, default_calendar="default"):
    """根据关键词自动判断日历归属"""
    text_lower = text.lower()
    scores = {}

    for cal_name, keywords in CALENDAR_HINTS.items():
        score = sum(1 for kw in keywords if kw in text)
        if score > 0:
            scores[cal_name] = score

    if scores:
        # 返回得分最高的
        return max(scores, key=scores.get)

    return default_calendar


def format_time(dt, fmt="%Y-%m-%dT%H:%M:%S"):
    """格式化时间为 ISO 格式"""
    return dt.strftime(fmt)


def parse(text, username="default"):
    """
    主解析函数
    输入: 自然语言文本
    输出: 结构化 dict
    """
    # 解析时间
    start_dt, time_method = parse_time(text)
    # 默认持续1小时
    end_dt = start_dt + timedelta(hours=1)

    # 解析地点
    location = parse_location(text)

    # 解析标题
    title = parse_title(text)

    # 解析备注
    description = parse_description(text, location)
    if location and location not in description:
        if description:
            description = f"地点：{location}。{description}"
        else:
            description = f"地点：{location}"

    # 解析日历归属
    calendar = parse_calendar(text)

    # 置信度
    confidence = "high" if time_method != "default" else "medium"

    result = {
        "title": title,
        "start_time": format_time(start_dt),
        "end_time": format_time(end_dt),
        "start_display": start_dt.strftime("%Y年%m月%d日 %H:%M"),
        "end_display": end_dt.strftime("%H:%M"),
        "location": location,
        "description": description,
        "calendar": calendar,
        "calendar_uri": calendar.lower(),
        "username": username,
        "confidence": confidence,
        "time_method": time_method,
        "raw_text": text,
    }

    return result


def main():
    args = sys.argv[1:]
    username = "default"
    text = ""
    json_only = False

    i = 0
    while i < len(args):
        if args[i] == "--username" and i + 1 < len(args):
            username = args[i + 1]
            i += 2
        elif args[i] == "--json":
            json_only = True
            i += 1
        elif args[i] == "--help" or args[i] == "-h":
            print(__doc__)
            sys.exit(0)
        else:
            text += args[i]
            i += 1

    if not text.strip():
        print(json.dumps({"error": "请提供日程描述"}, ensure_ascii=False))
        sys.exit(1)

    result = parse(text.strip(), username)

    if json_only:
        print(json.dumps(result, ensure_ascii=False, indent=2))
    else:
        # 友好输出
        print(f"📅 日程解析结果")
        print(f"  标题:    {result['title']}")
        print(f"  时间:    {result['start_display']} - {result['end_display']}")
        print(f"  地点:    {result['location'] or '(未指定)'}")
        print(f"  日历:    {result['calendar']}")
        print(f"  备注:    {result['description'] or '(无)'}")
        print(f"  置信度:  {result['confidence']}")
        print()
        print(f"  JSON: {json.dumps(result, ensure_ascii=False)}")


if __name__ == "__main__":
    main()
