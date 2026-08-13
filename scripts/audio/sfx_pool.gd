## sfx_pool.gd — 音效播放器池（autoload 注册名：SfxPool）
## 职责：AudioStreamPlayer3D 池（轮转复用，不每次 new）+ AudioStreamPlayer 2D 池（全局非定位）；
##       事件表驱动（data/audio_events.json，改 JSON 重启生效）：play_3d/play_2d 事件→资源播放；
##       每事件独立参数：多变体随机 / pitch 变调 / volume_db / max_distance / bus / 同帧限流 / loop；
##       JSON 缺失/损坏回退内置最小表（保持旧版行为）；素材缺失静默跳过（load 失败不播放不报错）
## 输入：weapon_base（开火/换弹/空仓）、player_controller（脚步/跳跃/落地/切枪）、player_state（受击/倒地/死亡/救援）、
##       door（开门）、pickup_item/supply_point（拾取）、zombie_ai（嘶吼/死亡）、wave_manager（尸潮警报）等调用
## 输出：3D 事件在 world_pos 定位播放；2D 事件（警报/UI）全局不衰减（Audio Bus: SFX/UI）
## 谁调用：任意端本地播放（视觉层，tech-plan §4.2；服务器不参与音效结算）
## 规范：池大小 3D=10 / 2D=4；事件定义全量见 docs/项目文档/02-设计/02-设计-音频-系统设计.md §5（字段说明）；
##       短音效 .ogg（Kenney 入库）；总线结构见 default_bus_layout.tres

extends Node

const EVENT_TABLE_PATH := "res://data/audio_events.json"
const AUDIO_ROOT := "res://assets/audio/"
const POOL_SIZE := 10
const POOL_SIZE_2D := 4
const BUS_NAME := "SFX"
## 3D 音效最大可闻距离默认值（音频方向 §4.1：默认 2000 太长，设 40-80m）
const MAX_DISTANCE := 60.0

## 内置回退事件表（JSON 缺失/解析失败时兜底，等价旧版 EVENT_MAP/EVENT_PITCH 行为）
const FALLBACK_EVENTS := {
	"pistol_fire": {"files": ["sfx/sfx_weapon_pistol_fire_01.ogg", "sfx/sfx_weapon_pistol_fire_02.ogg", "sfx/sfx_weapon_pistol_fire_03.ogg"]},
	"shotgun_fire": {"files": ["sfx/sfx_weapon_shotgun_fire_01.ogg", "sfx/sfx_weapon_shotgun_fire_02.ogg", "sfx/sfx_weapon_shotgun_fire_03.ogg"]},
	"zombie_hurt": {"files": ["sfx/sfx_zombie_hurt_01.ogg", "sfx/sfx_zombie_hurt_02.ogg", "sfx/sfx_zombie_hurt_03.ogg"]},
	"zombie_died": {"files": ["sfx/sfx_zombie_died_01.ogg", "sfx/sfx_zombie_died_02.ogg", "sfx/sfx_zombie_died_03.ogg"]},
	"player_hurt": {"files": ["sfx/sfx_player_hurt_01.ogg", "sfx/sfx_player_hurt_02.ogg"], "volume_db": -4.0},
	"hit_confirm": {"files": ["sfx/sfx_hit_confirm_01.ogg", "sfx/sfx_hit_confirm_02.ogg", "sfx/sfx_hit_confirm_03.ogg"], "volume_db": -6.0},
	"zombie_growl": {"files": ["sfx/sfx_zombie_growl_01.ogg"], "pitch": [0.55, 0.75]},
	"weapon_reload": {"files": ["sfx/sfx_weapon_reload_01.ogg"]},
	"weapon_reload_done": {"files": ["sfx/sfx_weapon_reload_done_01.ogg"]},
	"weapon_empty": {"files": ["sfx/sfx_weapon_empty_01.ogg"]},
	"wave_alarm": {"mode": "2d", "files": ["sfx/sfx_wave_alarm_01.ogg"], "pitch": [0.85, 0.95]},
}

var _events: Dictionary = {}
var _pool: Array[AudioStreamPlayer3D] = []
var _pool_2d: Array[AudioStreamPlayer] = []
var _cursor := 0
var _cursor_2d := 0
## 已成功加载的流缓存（只缓存有效流，避免重复 load；缺失不缓存）
var _stream_cache: Dictionary = {}
## 限流计数（每物理帧重置）
var _limit_frame := 0
var _limit_counts: Dictionary = {}


func _ready() -> void:
	_load_event_table()
	# 预建播放器池（轮转复用；音频方向 §4.5 播放器池 8-16）
	for i in POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.bus = BUS_NAME
		p.max_distance = MAX_DISTANCE
		p.unit_size = 1.0
		add_child(p)
		_pool.append(p)
	# 2D 全局池（警报/UI 类非定位音效；音频方向 §4.1 AudioStreamPlayer 不衰减）
	for i in POOL_SIZE_2D:
		var p2 := AudioStreamPlayer.new()
		p2.bus = BUS_NAME
		add_child(p2)
		_pool_2d.append(p2)


## 加载事件表（数据驱动；缺失/解析失败回退内置表并告警一次）
func _load_event_table() -> void:
	var file := FileAccess.open(EVENT_TABLE_PATH, FileAccess.READ)
	if file == null:
		push_warning("sfx_pool: 无法打开 %s，使用内置回退事件表" % EVENT_TABLE_PATH)
		_events = FALLBACK_EVENTS.duplicate(true)
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is Dictionary and (parsed as Dictionary).has("events"):
		_events = (parsed as Dictionary)["events"] as Dictionary
		return
	push_warning("sfx_pool: %s 解析失败，使用内置回退事件表" % EVENT_TABLE_PATH)
	_events = FALLBACK_EVENTS.duplicate(true)


## 播放 3D 音效：事件名 → 事件表（实际通道由事件 mode 决定：3d 走空间池 / 2d 走全局池）。
## 素材缺失（load 失败）静默跳过，不报错；限流同帧同事件 ≤ limit
func play_3d(event_name: String, world_pos: Vector3 = Vector3.ZERO) -> void:
	_play(event_name, world_pos)


## 播放全局 2D 音效（尸潮警报/UI）：不衰减、所有端本地播放；素材缺失静默跳过
func play_2d(event_name: String) -> void:
	_play(event_name, Vector3.ZERO)


## 事件统一播放入口：按事件表 mode 路由到 3D/2D 池（事件定义唯一，调用入口不限）
func _play(event_name: String, world_pos: Vector3) -> void:
	var ev: Variant = _events.get(event_name)
	if not (ev is Dictionary):
		return  # 事件未定义：静默
	var spec := ev as Dictionary
	if String(spec.get("mode", "3d")) == "2d":
		_play_2d(spec, event_name)
	else:
		_play_3d(spec, event_name, world_pos)


## 3D 空间播放（AudioStreamPlayer3D：位置定位 + 距离衰减）
func _play_3d(spec: Dictionary, event_name: String, world_pos: Vector3) -> void:
	if not _allow_event(event_name, spec):
		return  # 限流：同帧同事件超上限跳过（音频方向 §1）
	var path := _pick_file(spec)
	if path.is_empty():
		return
	var stream := _get_stream(path)
	if stream == null:
		return  # 素材未就位：静默容错（素材就位后即出声）
	_apply_loop(spec, stream)  # loop 是 AudioStream 属性（4.7 实测：AudioStreamPlayer 无 loop 字段）
	var player := _next_player()
	player.global_position = world_pos
	player.stream = stream
	player.bus = String(spec.get("bus", BUS_NAME))
	player.pitch_scale = _random_pitch(spec.get("pitch", 1.0))
	player.volume_db = float(spec.get("volume_db", 0.0))
	player.max_distance = float(spec.get("max_distance", MAX_DISTANCE))
	player.play()


## 全局 2D 播放（AudioStreamPlayer：不衰减；UI 事件可走 UI 总线）
func _play_2d(spec: Dictionary, event_name: String) -> void:
	if not _allow_event(event_name, spec):
		return  # 限流：与 3D 事件共用同帧计数
	var path := _pick_file(spec)
	if path.is_empty():
		return
	var stream := _get_stream(path)
	if stream == null:
		return  # 素材未就位：静默容错
	_apply_loop(spec, stream)
	var player := _next_player_2d()
	player.stream = stream
	player.bus = String(spec.get("bus", BUS_NAME))
	player.pitch_scale = _random_pitch(spec.get("pitch", 1.0))
	player.volume_db = float(spec.get("volume_db", 0.0))
	player.play()


## 循环播放（环境/音乐类事件预留）：loop 是 AudioStream 的属性（AudioStreamOggVorbis.loop 等），
## 在流上设置而非播放器；默认 false 不触碰（保持素材自身循环设置）
func _apply_loop(spec: Dictionary, stream: AudioStream) -> void:
	if bool(spec.get("loop", false)):
		stream.set("loop", true)


## 变体随机：files 数组随机选一（多变体防"复读机"）
func _pick_file(spec: Dictionary) -> String:
	var files: Variant = spec.get("files", [])
	if not (files is Array) or (files as Array).is_empty():
		return ""
	var list := files as Array
	if list.size() == 1:
		return String(list[0])
	return String(list[randi() % list.size()])


## 事件变调（未配置=1.0；float=固定 / Array[min,max]=随机；池复用前统一重置，防旧事件变调泄漏）
func _random_pitch(spec_pitch: Variant) -> float:
	if spec_pitch is float or spec_pitch is int:
		return float(spec_pitch)
	if spec_pitch is Array and (spec_pitch as Array).size() >= 2:
		return randf_range(float((spec_pitch as Array)[0]), float((spec_pitch as Array)[1]))
	return 1.0


## 取流（带缓存）；素材缺失静默跳过（先查文件存在，避免 load() 缺失路径打红色 ERROR）
func _get_stream(path: String) -> AudioStream:
	if _stream_cache.has(path):
		return _stream_cache[path]
	var full := AUDIO_ROOT + path
	if not FileAccess.file_exists(full):
		return null  # 素材未就位：静默跳过（就位后即出声）
	var stream := load(full) as AudioStream
	if stream != null:
		_stream_cache[full] = stream
	return stream


## 同帧限流：每物理帧每事件最多 limit 次（防霰弹多弹丸/高频刷屏；limit<=0 不限）
func _allow_event(event_name: String, spec: Dictionary) -> bool:
	var limit := int(spec.get("limit", 4))
	if limit <= 0:
		return true
	var frame := Engine.get_physics_frames()
	if frame != _limit_frame:
		_limit_frame = frame
		_limit_counts.clear()
	var count: int = _limit_counts.get(event_name, 0)
	if count >= limit:
		return false
	_limit_counts[event_name] = count + 1
	return true


## 轮转取播放器（全部占用时打断最早的一个）
func _next_player() -> AudioStreamPlayer3D:
	var p := _pool[_cursor]
	_cursor = (_cursor + 1) % _pool.size()
	if p.playing:
		p.stop()
	return p


## 轮转取 2D 播放器（同 3D：占用时打断最早的一个）
func _next_player_2d() -> AudioStreamPlayer:
	var p := _pool_2d[_cursor_2d]
	_cursor_2d = (_cursor_2d + 1) % _pool_2d.size()
	if p.playing:
		p.stop()
	return p
