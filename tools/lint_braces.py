import glob

PAIRS = {')': '(', ']': '[', '}': '{'}


def check(path):
    src = open(path, encoding='utf-8').read()
    i = 0
    n = len(src)
    stack = []
    line = 1
    in_line_comment = False
    in_block_comment = 0
    in_str = False
    delim = ''
    triple = False
    bs = chr(92)
    while i < n:
        c = src[i]
        if c == '\n':
            line += 1
            in_line_comment = False
            i += 1
            continue
        if in_line_comment:
            i += 1
            continue
        if in_block_comment:
            if src.startswith('*/', i):
                in_block_comment -= 1
                i += 2
                continue
            if src.startswith('/*', i):
                in_block_comment += 1
                i += 2
                continue
            i += 1
            continue
        if in_str:
            if src.startswith(bs, i):
                i += 2
                continue
            if triple:
                if src.startswith(delim * 3, i):
                    in_str = False
                    i += 3
                    continue
                i += 1
                continue
            if c == delim:
                in_str = False
                i += 1
                continue
            i += 1
            continue
        if src.startswith('//', i):
            in_line_comment = True
            i += 2
            continue
        if src.startswith('/*', i):
            in_block_comment = 1
            i += 2
            continue
        if src.startswith('"""', i):
            in_str = True
            triple = True
            delim = '"'
            i += 3
            continue
        if c in '"\'':
            in_str = True
            triple = False
            delim = c
            i += 1
            continue
        if c in '([{':
            stack.append((c, line))
            i += 1
            continue
        if c in ')]}':
            if not stack:
                return '%s:%d 多余的 %s' % (path, line, c)
            op, ol = stack.pop()
            if op != PAIRS[c]:
                return '%s:%d 期望 %s 的闭合却遇到 %s（开于第 %d 行）' % (path, line, op, c, ol)
            i += 1
            continue
        i += 1
    if stack:
        op, ol = stack[-1]
        return '%s: 第 %d 行的 %s 没有闭合' % (path, ol, op)
    if in_str:
        return '%s: 字符串没闭合' % path
    return None


bad = 0
for f in sorted(glob.glob('Cuiban/*.swift')):
    r = check(f)
    print(('OK   ' if r is None else 'FAIL ') + f + ('' if r is None else '  -> ' + r))
    if r:
        bad += 1
print('有问题的文件数: %d' % bad)
