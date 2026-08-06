# 美术来源记账（Model Sources · CREDITS）

> 纪律（总纲 §7 风险 7）：本项目美术素材一律 CC0 / 免费可商用；**CC0 也逐条记账**。
> 下载即登记：素材名 / 作者 / 来源链接 / 许可。侵权零容忍。
> 配套清单：`项目文档/02-设计/02-设计-美术-替换清单-M3.md`（替换对象/优先级/技术约束/获取步骤）。

## 已入库

| 日期 | 文件名（入库后） | 素材原名 | 作者 | 来源链接 | 许可 | 用途 |
|---|---|---|---|---|---|---|
| 2026-08-06 | `assets/models/characters/char_zombie_common_01.glb` | Zombie_Basic | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 普通丧尸瘦型（P0，方案 B 剥骨静态+程序化减面） |
| 2026-08-06 | `assets/models/characters/char_zombie_common_01.glb` 内嵌 | Zombie_Atlas.png | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 丧尸纹理 atlas（512×512，剥骨后内嵌） |
| （待入库） | `characters/char_zombie_common_02.glb` | Zombie_Chubby | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 普通丧尸壮型（P0，未入库） |
| （待入库） | `characters/char_zombie_charger.glb` | （Quaternius 壮硕/蛮族类改色） | Quaternius | https://quaternius.com/packs/ultimatemonsters.html | CC0 | 冲撞者（P1，未入库） |
| （待入库） | `characters/char_zombie_spitter.glb` | （Quaternius 肥胖/带瘤类改色） | Quaternius | https://quaternius.com/packs/ultimatemonsters.html | CC0 | 喷吐者（P1，未入库） |
| （待入库） | `characters/char_survivor_male_a.glb` | Ultimate Animated Character | Quaternius | https://quaternius.com/packs/ultimateanimatedcharacter.html | CC0 | 玩家 Body（P2，未入库） |
| （待入库） | `weapons/wep_*.glb` | FPS Kit | Kenney | https://kenney.nl/assets/fps-kit | CC0 | 武器 view/world ×4（P2，未入库） |
| （待入库） | `environment/env_block_*.glb` | Ultimate Modular Buildings / City Kit | Quaternius / Kenney | https://quaternius.com/packs/ultimatemodularbuildings.html / https://kenney.nl/assets/city-kit | CC0 | 环境模块（P3，未入库） |
| （待入库） | `props/prop_*.glb` | FPS Kit / City Kit | Kenney | https://kenney.nl/assets/fps-kit | CC0 | 道具箱（颜色已修正：弹药黄/橙、血包医疗绿；模型 P4 替换未入库） |

## 处理说明（M3-ART-P0）

- **来源包**：Quaternius Zombie Apocalypse Kit（https://quaternius.com/packs/zombieapocalypsekit.html），含 4 丧尸 + 4 角色 + 2 狗 + 大量环境，CC0。
- **未采用 Ultimate Monsters**（quaternius.com/packs/ultimatemonsters.html）：该包 Big/Blob/Flying 系列无 Zombie/普通丧尸人形，与 R1/R2 需求不匹配（清单 §5 降级预案允许）。
- **剥骨处理**：Blender 不可用（`where blender` 无输出，常见安装路径无）→ 走**程序化剥骨**（自研 strip_bones.py：bind pose 烘焙 POSITION/NORMAL/UV，移除 skins/animations/joints，输出无骨骼静态 .glb）。原 glTF 含 skins:1 + animations:9-16，剥骨后 skins:0/animations:0，单 mesh 节点。
- **减面处理**：pymeshlab Quadric Edge Collapse（planarquadric=True，preserveboundary=False，因边界保护会卡在 ~1800 tris）→ 999 tris（≤1200 目标达成；R1 规格 600-1000）。
- **纹理保留**：原 glTF image 嵌入 bufferView（PNG 512×512），剥骨脚本将图像数据重新打包进输出 .glb；trimesh 重建后 PBRMaterial.baseColorTexture 关联，Godot 导入生成 .ctex。
- **僵尸外观**：绿皮病态丧尸（Quaternius 原画），符合"病态"丧尸语义；场景中 Visual scale=1.45 校准到 ≈1.72m 高度，对齐 1.7m 胶囊碰撞。
- **临时脚本**：`../_tmp_art_xjtf_dl/`（项目外）保留原始下载与 strip_bones.py/rebuild_low_glb.py 工具脚本；不入库。
- **已知次优**：`zombie_ai_common.gd` 的 `_apply_visibility_range` 假设 `Visual` 是 GeometryInstance3D；glb 实例化为 Node3D 含子 mesh，cast 失败，visibility_range 60m 未直接生效（headless 不影响；真机轻微损失，P1 阶段可改 AI 脚本递归找 mesh）。

## 配色修正（M3-ART-P0 顺手）

| 道具 | 原色 | 新色 | 原因 |
|---|---|---|---|
| 弹药（supply_point/pickup_item MeshAmmo） | 蓝 #2673FF | 黄/橙 #FFC73C / #FF9933 | 美术方向铁律 2：可交互物暖色系，蓝紫留给环境；色盲友好（蓝 vs 红难辨，黄/橙 vs 绿高区分） |
| 医疗（supply_point/pickup_item MeshHealth） | 红 #FF3333 | 医疗绿 #3DDC84 | 美术方向 §1.2 血包=医疗绿；色盲友好 |

修改文件：`scenes/environment/supply_point.tscn`、`scenes/environment/pickup_item.tscn`（仅 sub_resource 材质颜色，节点结构不动）。

## 待办

- [x] 下载 Quaternius Ultimate Monsters → 评估：包内无 Zombie，跳过
- [x] 下载 Quaternius Zombie Apocalypse Kit → 普通丧尸 R1 剥骨导入（P0 完成）
- [ ] Zombie_Chubby 入库（壮型 P0 同包内）
- [ ] 道具 P4 道具模型替换（颜色已先改，模型沿用 BoxMesh 可降级）
- [ ] Kenney FPS Kit 下载 → 武器/道具（P2）
- [ ] 全部入库后按替换清单命名 + 逐条补全作者/链接/许可
