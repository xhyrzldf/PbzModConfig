"""Package JavaScript overrides as a matching pak/utoc/ucas container set."""
import argparse
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile


def parse_files(specs):
    files = {}
    for spec in specs:
        inner, separator, local = spec.partition("=")
        path = PurePosixPath(inner)
        if (not separator or not inner.startswith("ProjectPBZ/Content/")
                or "\\" in inner or ":" in inner or ".." in path.parts
                or path.is_absolute() or path.as_posix() != inner):
            raise ValueError(f"无效包内路径：{inner}")
        if inner in files:
            raise ValueError(f"重复包内路径：{inner}")
        source = Path(local)
        if not source.is_file():
            raise ValueError(f"源文件不存在：{local}")
        files[inner] = source
    return files


def run(command):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f"命令失败（{result.returncode}）：{command[0]}\n{result.stdout}\n{result.stderr}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repak", type=Path, required=True)
    parser.add_argument("--retoc", type=Path, required=True)
    parser.add_argument("--file", action="append", required=True)
    args = parser.parse_args()
    if not args.name.endswith("_P") or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-" for c in args.name):
        parser.error("名称只能包含字母、数字、下划线和短横线，并以 _P 结尾")
    files = parse_files(args.file)
    out = args.out.resolve()
    allowed = Path(__file__).resolve().parent.parent / ".local"
    if out == allowed.resolve() or not out.is_relative_to(allowed.resolve()):
        parser.error("输出必须位于仓库 .local 下的独立子目录")
    for ext in ("pak", "utoc", "ucas"):
        if (out / f"{args.name}.{ext}").exists():
            parser.error("目标产物已存在，请使用新的构建目录")
    for tool in (args.repak, args.retoc):
        if not tool.is_file():
            parser.error(f"工具不存在：{tool}")
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="pack-", dir=out) as temporary:
        stage = Path(temporary) / "stage"
        for inner, source in files.items():
            target = stage / inner
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        run([str(args.retoc.resolve()), "to-zen", "--version", "UE5_7", str(stage), str(out / f"{args.name}.utoc")])
        pak = out / f"{args.name}.pak"
        run([str(args.repak.resolve()), "pack", "-q", "--version", "V11", "--mount-point", "../../../", str(stage), str(pak)])
        listed = set(run([str(args.repak.resolve()), "list", str(pak)]).splitlines())
        if listed != set(files):
            raise RuntimeError(f"包内清单不一致；缺失：{sorted(set(files) - listed)}；额外：{sorted(listed - set(files))}")
    for ext in ("pak", "utoc", "ucas"):
        artifact = out / f"{args.name}.{ext}"
        print(f"{hashlib.sha256(artifact.read_bytes()).hexdigest()}  {artifact.stat().st_size}  {artifact.name}")


if __name__ == "__main__":
    main()
