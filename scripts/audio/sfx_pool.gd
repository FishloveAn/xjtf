## sfx_pool.gd — 音效播放器池（autoload 注册名：SfxPool）
## 职责：AudioStreamPlayer3D 池（轮转复用，不每枪 new）；play_3d(event_name, world_pos) 事件→资源播放；
##       素材缺失静默跳过（load 失败不播放不报错，素材就位即生效）
## 输入：weapon_base（开火/命中）、zombie_ai（死亡）、player_state（受击）等调用 play_3d
## 输出：在 world_pos 用 3D 定位播放对应事件音效（Audio Bus: SFX）
## 谁调用：任意端本地播放（视觉层，tech-plan §4.2；服务器不参与音效结算）
## 规范：池大小 8-12；事件→路径 const 映射（命名对齐 audio-director 清单 §4.4，未到先用占位名）；
##       短音效 .wav、长音频 .ogg（音频方向 §4.3）；总线结构见 default_bus_layout.tres

extends Node

const POOL_SIZE := 10
const BUS_NAME := "SFX"
## 3D 音效最大可闻距离（音频方向 §4.1：默认 2000 太长，设 40-80m）
const MAX_DISTANCE := 60.0
## 限流：同帧同事件最多播放数（音频方向 §1：同帧同事件 ≤4，防霰弹 8 弹丸刷屏）
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
}

var _pool: Array[AudioStreamPlayer3D] = []
var _cursor := 0
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
	player.play()


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
