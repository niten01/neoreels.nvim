"""Optional real mouse-event integration test; requires Python msgpack."""
import subprocess
import time
import os
import select
from pathlib import Path

import msgpack


def main():
    proc = subprocess.Popen(["nvim", "--embed", "-n", "-u", "NONE", "-i", "NONE"],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    unpacker = msgpack.Unpacker(raw=False)
    request = 0

    def call(method, *args):
        nonlocal request
        request += 1
        proc.stdin.write(msgpack.packb([0, request, method, args], use_bin_type=True))
        proc.stdin.flush()
        deadline = time.monotonic() + 10
        while True:
            for message in unpacker:
                if message[0] == 1 and message[1] == request:
                    if message[2]:
                        raise RuntimeError(message[2])
                    return message[3]
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([proc.stdout], [], [], remaining)[0]:
                raise TimeoutError("Neovim did not reply to " + method)
            data = os.read(proc.stdout.fileno(), 65536)
            if not data:
                raise RuntimeError("Neovim closed before replying")
            unpacker.feed(data)

    def lua(code):
        return call("nvim_exec_lua", code, [])

    def status():
        return lua('return require("neoreels").status()')

    try:
        call("nvim_ui_attach", 120, 60, {"ext_linegrid": True})
        root = str(Path(__file__).resolve().parents[1])
        editor = call("nvim_get_current_win")
        original_width = call("nvim_win_get_width", editor)
        call("nvim_buf_set_lines", 0, 0, -1, False, ["This text must remain visible. " * 8])
        call("nvim_set_option_value", "wrap", False, {"win": editor})
        call("nvim_exec_lua", 'local root=...; vim.opt.runtimepath:prepend(root); vim.o.mouse="a"; local h=dofile(root.."/tests/helpers.lua"); local f=h.fixture(); vim.g.neoreels_ui_fixture=f.base; h.start(f)', [root])
        deadline = time.monotonic() + 5
        while status().get("frames", 0) < 2 and time.monotonic() < deadline:
            time.sleep(0.05)
        assert status().get("frames", 0) >= 2, "Player did not render"
        assert call("nvim_get_current_win") == editor
        before = status()
        geometry = call("nvim_win_get_config", before["window"])
        assert before["dock"] and call("nvim_win_get_width", editor) < original_width
        assert call("nvim_get_option_value", "wrap", {"win": editor})
        assert lua('return vim.fn.screenpos(vim.api.nvim_get_current_win(),1,110).row') > 1, "Text did not wrap beside Reels"
        assert call("nvim_win_get_width", editor) <= geometry["col"], "Reel overlaps text"
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
        assert call("nvim_win_get_width", editor) <= call("nvim_win_get_config", after["window"])["col"]
        print("neoreels: real UI mouse drag passed")
        call("nvim_ui_try_resize", 90, 45)
        time.sleep(0.05)
        geometry = call("nvim_win_get_config", status()["window"])
        assert call("nvim_win_get_width", editor) <= geometry["col"], "UI resize overlaps buffer"
        assert geometry["col"] + geometry["width"] + 2 <= 90
        lua('require("neoreels").stop()')
        assert not call("nvim_win_is_valid", before["dock"]), "Dock remains after stop"
        assert call("nvim_win_get_width", editor) == 90, "Editor width not restored"
        assert not call("nvim_get_option_value", "wrap", {"win": editor}), "Original nowrap setting not restored"
        print("neoreels: real UI wrapping, no overlap, resize, and restoration passed")
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
