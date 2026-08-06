# 美术来源记账（Model Sources · CREDITS）

> 纪律（总纲 §7 风险 7）：本项目美术素材一律 CC0 / 免费可商用；**CC0 也逐条记账**。
> 下载即登记：素材名 / 作者 / 来源链接 / 许可。侵权零容忍。
> 配套清单：`项目文档/02-设计/02-设计-美术-替换清单-M3.md`（替换对象/优先级/技术约束/获取步骤）。

## 已入库

| 日期 | 文件名（入库后） | 素材原名 | 作者 | 来源链接 | 许可 | 用途 |
|---|---|---|---|---|---|---|
| 2026-08-06 | `assets/models/characters/char_zombie_common_01.glb` | Zombie_Basic | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 普通丧尸瘦型（P0，方案 B 剥骨静态+程序化减面） |
| 2026-08-06 | `assets/models/characters/char_zombie_common_01.glb` 内嵌 | Zombie_Atlas.png | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 丧尸纹理 atlas（512×512，剥骨后内嵌） |
| 2026-08-06 | `assets/models/characters/char_zombie_charger_01.glb` | Zombie_Chubby | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 冲撞者（P1，**保留骨骼+6 动画**，顶点聚类减面+纹理染橙） |
| 2026-08-06 | `assets/models/characters/char_zombie_charger_01.glb` 内嵌 | Zombie_Atlas.png（染橙） | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 特感纹理（颈/身体绿区 → 信号橙 #FF7A2F） |
| 2026-08-06 | `assets/models/characters/char_zombie_spitter_01.glb` | Zombie_Ribcage | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 喷吐者（P1，**保留骨骼+6 动画**，顶点聚类减面+纹理染黄绿） |
| 2026-08-06 | `assets/models/characters/char_zombie_spitter_01.glb` 内嵌 | Zombie_Atlas.png（染黄绿） | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 特感纹理（颈/身体绿区 → 腐绿黄 #7A8A66 偏黄） |
| （待入库） | `characters/char_zombie_common_02.glb` | Zombie_Chubby | Quaternius | https://quaternius.com/packs/zombieapocalypsekit.html | CC0 | 普通丧尸壮型（**P1 冲撞者已占用 Chubby**，R2 需换替代或降级） |
| （待入库） | `characters/char_zombie_charger.glb` | （P1 已入库，特感同名） | Quaternius | https://quaternius.com/packs/ultimatemonsters.html | CC0 | 冲撞者（P1，已入库到 `char_zombie_charger_01.glb`） |
| （待入库） | `characters/char_zombie_spitter.glb` | （P1 已入库，特感同名） | Quaternius | https://quaternius.com/packs/ultimatemonsters.html | CC0 | 喷吐者（P1，已入库到 `char_zombie_spitter_01.glb`） |
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

## 处理说明（M3-ART-P1）

- **来源包**：Quaternius Zombie Apocalypse Kit（同 P0 包，CC0）。Chubby/Ribcage 来自同包内 `Characters/Blends`（P0 strip_bones 时未使用）。
- **模型选择**：
  - **冲撞者 = Zombie_Chubby**（胖丧尸 1.49m × 1.67m，**大体型壮硕** 匹配任务描述）→ 改色信号橙 #FF7A2F
  - **喷吐者 = Zombie_Ribcage**（肋骨外露瘦尸 1.05m × 0.51m，**瘦高独特轮廓** 匹配任务描述）→ 改色腐绿黄 #7A8A66 偏黄
  - **R2 普通丧尸壮型受影响**：Chubby 已用于冲撞者，R2 需 P2 换替代（沿用 Basic 换皮 / Poly Pizza CC0 替代）；**当前可降级**（P0 已声明 R2 可降级）。
- **动画处理**：原 glTF 16/9 个动画，按任务规范裁剪重命名为 6 槽 `idle/walk/attack/hurt/death/spawn`：
  - Charger (Chubby)：Idle→idle, Walk→walk, Idle_Attack→attack, HitReact→hurt, Death→death, Jump_Land→spawn
  - Spitter (Ribcage)：Idle→idle, Walk→walk, **Idle(复制)→attack**（无攻击动画用站定姿态替代，任务 §2.3 允许）, HitReact→hurt, Death→death, Jump_Land→spawn
- **保留骨骼**：原 glTF skins:1 保留，JOINTS_0/WEIGHTS_0 完整（限制最大 48 关节 < 256 → 数组用 ubyte 5121）。
- **顶点聚类减面**：`tools/../_tmp_art_xjtf_dl/process_special.py`（自研，纯 numpy，无 Blender）→ voxel 0.04m 合并相邻顶点，三角形因三顶点重叠塌缩删除。**保留全部属性**（POSITION/NORMAL/TEXCOORD_0/COLOR_0/JOINTS_0/WEIGHTS_0）。
- **tris 预算**：Charger 6174→3393、Spitter 4774→1774（原 2000-4000 预算，Spitter 偏低 11% 因模型本身顶点数稀疏，几何细节天然少）。
- **纹理染色**：Pillow 处理内嵌的 Zombie_Atlas.png，绿主导像素按规则转色（Charger 绿→橙 RGB 系数 (1.0,0.48,0.18)；Spitter 绿→黄绿 (0.75,1.05,0.28)），非绿区保留原色。512×512 PNG 内嵌 glb，单纹理。
- **GLB 嵌入**：移除 buffers[0].uri 字段（GLB 容器内嵌 BIN，Godot 4.7 看到空字符串会找外部 .bin 报错）。accessor.indices.count = 元素总数（n×3），不要写成行数（4.7 严格 3 倍数校验）。
- **场景保留结构**：`zombie_charger.tscn` / `zombie_spitter.tscn` 节点结构不变（Visual 替换为 glb 实例 scale 1.45/1.81，碰撞（capsule r=0.5 h=2.1）/AI/Health/SpecialSync/Hitbox/BloodPuff 全部保留）。
- **动画接线**：`zombie_ai_special.gd` 基类加 `_anim_player`（_ready 时 find_child 查找）+ `_play_anim(slot)`；子类（Charger/Spitter）在状态切换点调用 `_play_anim("walk"/"attack"/"hurt"/"death")`，spawn 由基类 `_bind_anim_player` 初始化时自动播一次。
- **新增工具**：`tools/_inspect_special_glb.gd`（headless 验证 glb 结构：节点树/动画/Skeleton/Mesh/texture）
- **临时脚本**：`../_tmp_art_xjtf_dl/process_special.py`（自研着色/Pillow；不入库；临时工具文档保留以供 P2 玩家 body 复用）
- **debug 加动画验证**：`debug_charger.gd` / `debug_spitter.gd` 步骤①加 `_verify_special_anim`（查 AnimationPlayer 存在 + 6 槽名 + current_animation=spawn）

## 配色修正（M3-ART-P0 顺手）

| 道具 | 原色 | 新色 | 原因 |
|---|---|---|---|
| 弹药（supply_point/pickup_item MeshAmmo） | 蓝 #2673FF | 黄/橙 #FFC73C / #FF9933 | 美术方向铁律 2：可交互物暖色系，蓝紫留给环境；色盲友好（蓝 vs 红难辨，黄/橙 vs 绿高区分） |
| 医疗（supply_point/pickup_item MeshHealth） | 红 #FF3333 | 医疗绿 #3DDC84 | 美术方向 §1.2 血包=医疗绿；色盲友好 |

修改文件：`scenes/environment/supply_point.tscn`、`scenes/environment/pickup_item.tscn`（仅 sub_resource 材质颜色，节点结构不动）。

## 待办

- [x] 下载 Quaternius Ultimate Monsters → 评估：包内无 Zombie，跳过
- [x] 下载 Quaternius Zombie Apocalypse Kit → 普通丧尸 R1 剥骨导入（P0 完成）
- [x] **M3-ART-P1 特感替换**：Charger（Chubby 保留骨骼染橙）+ Spitter（Ribcage 保留骨骼染黄绿）+ 6 动画裁剪重命名 + 动画状态接线 + 记账
- [ ] R2 普通丧尸壮型（Chubby 已被 P1 占用，需换替代或降级）
- [ ] 道具 P4 道具模型替换（颜色已先改，模型沿用 BoxMesh 可降级）
- [ ] Kenney FPS Kit 下载 → 武器/道具（P2）
- [ ] 全部入库后按替换清单命名 + 逐条补全作者/链接/许可
