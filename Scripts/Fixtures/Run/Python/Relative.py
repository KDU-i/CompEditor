from pathlib import Path
print(Path('fixture-data.txt').read_text(encoding='utf-8'), end='')
