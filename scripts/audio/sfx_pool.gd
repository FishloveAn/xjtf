## sfx_pool.gd — 音效播放器池（autoload 注册名：SfxPool）
## 职责：AudioStreamPlayer3D 池（轮转复用，不每枪 new）+ AudioStreamPlayer 2D 池（全局非定位）；
##       play_3d(event_name, world_pos) / play_2d(event_name) 事件→资源播放；
##       素材缺失静默跳过（load 失败不播放不报错，素材就位即生效）
## 输入：weapon_base（开火/换弹/空仓）、zombie_ai（嘶吼/死亡）、wave_manager（尸潮警报）等调用
## 输出：3D 事件在 world_pos 定位播放；2D 事件（警报/UI）全局不衰减（Audio Bus: SFX）
## 谁调用：任意端本地播放（视觉层，tech-plan §4.2；服务器不参与音效结算）
## 规范：池大小 8-12；事件→路径 const 映射（命名对齐 audio-director 清单 §4.4，未到先用占位名）；
##       EVENT_PITCH 变调（音频方向 §4.4：pitch_scale 制造差异/低音变调，只用真实 CC0 素材）；
##       短音效 .wav、长音频 .ogg（音频方向 §4.3）；总线结构见 default_bus_layout.tres

extends Node

const POOL_SIZE := 10
const POOL_SIZE_2D := 4
const BUS_NAME := "SFX"
## 3D 音效最大可闻距离（音频方向 §4.1：默认 2000 太长，设 40-80m）
const MAX_DISTANCE := 60.0
## 限流：同帧同事件最多播放数（音频方向 §1：同帧同事件 ≤4，防霰弹 8 弹丸刷屏/80 只同时嘶吼）
const EVENT_LIMIT := 4

## 事件 → 资源路径（AUD02 已入库 Kenney CC0，扩展名 .ogg；枪声为 impactMetal 打击层占位，待 freesound CC0 替换）
const EVENT_MAP := {
	"pistol_fire": "res://assets/audio/sfx/sfx_weapon_pistol_fire_01.ogg",
	"shotgun_fire": "res://assets/audio/sfx/sfx_weapon_shotgun_fire_01.ogg",
	"zombie_hurt": "res://assets/audio/sfx/sfx_zombie_hurt_01.ogg",
	"zombie_died": "res://assets/audio/sfx/sfx_zombie_died_01.ogg",
	"player_hurt": "res://assets/audio/sfx/sfx_player_hurt_01.ogg",
	"hit_confirm": "res://assets/audio/sfx/sfx_hit_confirm_01.ogg",
	"charge_windup": "res://assets/audio/sfx/sfx_charge_windup_01.ogg",
	"charger_hit": "res://assets/audio/sfx/sfx_charger_hit_01.ogg",
	"charger_death": "res://assets/audio/sfx/sfx_charger_death_01.ogg",
	# M3-S3 喷吐者：吐酸前摇 / 酸液落地（素材未到静默跳过，M1-S7 容错）
	"spit_windup": "res://assets/audio/sfx/sfx_spit_windup_01.ogg",
	"acid_land": "res://assets/audio/sfx/sfx_acid_land_01.ogg",
	"spitter_death": "res://assets/audio/sfx/sfx_spitter_death_01.ogg",
	# M3-S7 P1：丧尸嘶吼 / 换弹（开始+上膛）/ 空仓 / 尸潮警报（Kenney CC0 已入库，2026-08-06）
	"zombie_growl": "res://assets/audio/sfx/sfx_zombie_growl_01.ogg",
	"weapon_reload": "res://assets/audio/sfx/sfx_weapon_reload_01.ogg",
	"weapon_reload_done": "res://assets/audio/sfx/sfx_weapon_reload_done_01.ogg",
	"weapon_empty": "res://assets/audio/sfx/sfx_weapon_empty_01.ogg",
	"wave_alarm": "res://assets/audio/sfx/sfx_wave_alarm_01.ogg",
}

## 事件 → 变调（音频方向 §4.4 pitch_scale）：float=固定 / Array[min,max]=随机。
## 嘶吼用 impactSoft 重击降调 0.55-0.75 模拟低频咆哮（真实 CC0 变调，不伪造）；警报略降调压氛围。
## 未列入的事件 pitch=1.0；池复用前必重置（防旧事件变调泄漏到下一事件）。
const EVENT_PITCH := {
	"zombie_growl": [0.55, 0.75],
	"wave_alarm": [0.85, 0.95],
}

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


## 播放 3D 音效：事件名 → 资源路径。素材缺失（load 失败）静默跳过，不报错
func play_3d(event_name: String, world_pos: Vector3 = Vector3.ZERO) -> void:
	var path: String = EVENT_MAP.get(event_name, "")
	if path.is_empty():
		return
	if not _allow_event(event_name):
		return  # 限流：同帧同事件超上限跳过（音频方向 §1）
	var stream := _get_stream(path)
	if stream == null:
		return  # 素材未就位：静默容错（S7；素材就位后即出声）
	var player := _next_player()
	player.global_position = world_pos
	player.stream = stream
	player.pitch_scale = _random_pitch(event_name)
	player.play()


## 播放全局 2D 音效（尸潮警报/UI）：不衰减、所有端本地播放；素材缺失静默跳过
func play_2d(event_name: String) -> void:
	var path: String = EVENT_MAP.get(event_name, "")
	if path.is_empty():
		return
	if not _allow_event(event_name):
		return  # 限流：与 3D 事件共用同帧计数（音频方向 §1）
	var stream := _get_stream(path)
	if stream == null:
		return  # 素材未就位：静默容错
	var player := _next_player_2d()
	player.stream = stream
	player.pitch_scale = _random_pitch(event_name)
	player.play()


## 事件变调（未配置=1.0；池复用前统一重置，防旧事件变调泄漏）
func _random_pitch(event_name: String) -> float:
	var spec: Variant = EVENT_PITCH.get(event_name, 1.0)
	if spec is float:
		return spec
	if spec is Array and (spec as Array).size() >= 2:
		return randf_range(float((spec as Array)[0]), float((spec as Array)[1]))
	return 1.0


## 取流（带缓存）；素材缺失静默跳过（先查文件存在，避免 load() 缺失路径打红色 ERROR）
func _get_stream(path: String) -> AudioStream:
	if _stream_cache.has(path):
		return _stream_cache[path]
	if not FileAccess.file_exists(path):
		return null  # 素材未就位：静默跳过（S7；素材就位后即出声）
	var stream := load(path) as AudioStream
	if stream != null:
		_stream_cache[path] = stream
	return stream


## 同帧限流：每物理帧每事件最多 EVENT_LIMIT 次（防霰弹多弹丸/高频刷屏）
func _allow_event(event_name: String) -> bool:
	var frame := Engine.get_physics_frames()
	if frame != _limit_frame:
		_limit_frame = frame
		_limit_counts.clear()
	var count: int = _limit_counts.get(event_name, 0)
	if count >= EVENT_LIMIT:
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
