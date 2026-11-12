# 学习与开发笔记

按《OpenGL 与迷你农场》的课程大纲依次学习，每节学完后再讨论当前项目需要做什么。
结合课程和参考源码完善 TinyFarm，并评估其中的共用能力或亮点是否适合引入 ZhuYu。

不提前安排后续章节的任务。笔记只记录学习中实际提出的问题、讨论后确定的待办，
以及必要的结论；完成事项用一句话记录。

## 本地路径

| 项目 | 路径 |
| --- | --- |
| 当前 Zig TinyFarm | `/root/github/TinyFarm` |
| ZhuYu 引擎 | `/root/github/ZhuYu` |
| C++ TinyFarm 参考源码 | `/root/github/study/TinyFarm` |
| 课程仓库 | `/root/github/study/cppgamedev` |
| 主要课程 | `/root/github/study/cppgamedev/backend/src/courses/OpenGL与迷你农场/` |
| 其他参考项目 | `/root/github/study` |

C++ TinyFarm 的 `src/game/` 是游戏实现，`src/engine/` 是引擎实现。
课程正文按文件名中的章节编号依次阅读，并结合对应源码讨论。

关联本地 ZhuYu 构建和测试：

```sh
zig build --fork /root/github/ZhuYu
zig build test --fork /root/github/ZhuYu
```
