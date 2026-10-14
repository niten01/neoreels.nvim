"""Optional real mouse-event integration test; requires Python msgpack."""
import subprocess
import time
from pathlib import Path

import msgpack


def main():
    proc = subprocess.Popen(["nvim", "--embed", "-u", "NONE", "-i", "NONE"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    unpacker = msgpack.Unpacker(proc.stdout, raw=False, read_size=1)
    request = 0

    def call(method, *args):
        nonlocal request
        request += 1
        proc.stdin.write(msgpack.packb([0, request, method, args], use_bin_type=True))
        proc.stdin.flush()
        for message in unpacker:
            if message[0] == 1 and message[1] == request:
                if message[2]:
                    raise RuntimeError(message[2])
                return message[3]
        raise RuntimeError("Neovim closed before replying")

    def lua(code):
        return call("nvim_exec_lua", code, [])

    def status():
        return lua('return require("neoreels").status()')

    try:
        call("nvim_ui_attach", 120, 60, {"ext_linegrid": True})
        root = str(Path(__file__).resolve().parents[1])
        call("nvim_exec_lua", 'local root=...; vim.opt.runtimepath:prepend(root); vim.o.mouse="a"; local h=dofile(root.."/tests/helpers.lua"); local f=h.fixture(); vim.g.neoreels_ui_fixture=f.base; h.start(f)', [root])
        deadline = time.monotonic() + 5
        while status().get("frames", 0) < 2 and time.monotonic() < deadline:
            time.sleep(0.05)
        assert status().get("frames", 0) >= 2, "Player did not render"
        editor = call("nvim_get_current_win")
        before = status()
        geometry = call("nvim_win_get_config", before["window"])
        row, col = int(geometry["row"]), int(geometry["col"])
        call("nvim_input_mouse", "left", "press", "", 0, row, col)
        time.sleep(0.05)
        call("nvim_input_mouse", "left", "drag", "", 0, row - 4, col - 8)
        time.sleep(0.05)
        call("nvim_input_mouse", "left", "release", "", 0, row - 4, col - 8)
        time.sleep(0.05)
        after = status()
        assert (after["width"], after["height"]) == (48, 40), after
        assert after["window"] == before["window"] and after["buffer"] == before["buffer"]
        assert call("nvim_get_current_win") == editor, "Mouse drag stole editor focus"
        print("neoreels: real UI mouse drag passed")
        lua('require("neoreels").stop()')
    finally:
        if proc.poll() is None:
            try:
                lua('require("neoreels").stop(); if vim.g.neoreels_ui_fixture then vim.fn.delete(vim.g.neoreels_ui_fixture, "rf") end')
            except Exception:
                pass
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


if __name__ == "__main__":
    main()
