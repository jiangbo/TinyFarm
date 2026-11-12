# TinyFarm · 迷你农场

一个使用 Zig 编写的 2D 农场游戏，基于 [ZhuYu](https://github.com/jiangbo/ZhuYu)
引擎和 [MiGu](https://github.com/jiangbo/MiGu) ECS。

参考 C++ TinyFarm 的源码和《OpenGL 与迷你农场》课程，逐步完善游戏，项目仍在开发中。

![游戏截图](readme.png)

## 构建与运行

使用 Zig 0.17.1，在项目目录执行：

```sh
zig build run
```

构建和测试：

```sh
zig build
zig build test
```

原生产物位于 `zig-out/bin/`，包括可执行文件 `demo` 和 `assets/`。

```sh
zig build -Doptimize=fast
```

Web 构建需先安装 Emscripten，产物位于 `zig-out/web/`：

```sh
zig build install-emsdk -Dtarget=wasm32-emscripten
zig build -Dtarget=wasm32-emscripten
```

## 操作

| 按键 | 操作 |
| --- | --- |
| WASD / 方向键 | 移动 |
| F | 交互 |
| I | 物品栏 |
| Tab | 切换快捷栏 |
| 1–9、0 | 选择快捷栏槽位 |
| P / Esc | 暂停 |
| X | 切换调试信息 |

## 参考

- [C++ TinyFarm](https://github.com/WispSnow/TinyFarm)
- [C++ 游戏开发之旅](https://github.com/WispSnow/cppgamedev)