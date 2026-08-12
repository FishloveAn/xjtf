## synth_audio.py — 程序化音效合成器（2026-08-07 音频补全）
## 用途：为《星际土匪》补全 Kenney 包覆盖不到的缺失音效（写实枪声/玩家拟声/特感咆哮）。
##       输出 .ogg（soundfile/liboggvorbis），原创生成零版权风险；按 audio_events.json 命名规范入库即生效。
## 用法：python synth_audio.py   （输出到 assets/audio/sfx/）
## 设计依据：02-设计-音频-系统设计.md §4.1 音色区分度表 / 素材缺口行动清单 §2.2
## 工具：numpy + soundfile（managed venv：C:\Users\668\.workbuddy\binaries\python\envs\default）

import os
import numpy as np
import soundfile as sf

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio", "sfx")
OUT = os.path.normpath(OUT)


# ---------- 基础 DSP 工具 ----------

def t(n):
    return np.arange(n) / SR


def env_exp(n, tau):
    """指数衰减包络（tau 秒）"""
    return np.exp(-np.arange(n) / (tau * SR))


def env_rise(n, k=2.0):
    """渐强包络 (t/n)^k"""
    return (np.linspace(0.0, 1.0, n)) ** k


def noise(n, seed):
    return np.random.default_rng(seed).standard_normal(n)


def band(x, lo, hi):
    """FFT 带通（简单陡峭）"""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1.0 / SR)
    X[(f < lo) | (f > hi)] = 0.0
    return np.fft.irfft(X, len(x))


def sine(freq, n, phase0=0.0):
    return np.sin(2.0 * np.pi * freq * t(n) + phase0)


def saw(freq, n):
    """锯齿波（-1..1）"""
    return 2.0 * ((freq * t(n)) % 1.0) - 1.0


def chirp_sine(f0, f1, n):
    """线性扫频正弦"""
    k = (f1 - f0) / (n / SR)
    phase = 2.0 * np.pi * (f0 * t(n) + 0.5 * k * t(n) ** 2)
    return np.sin(phase)


def bubbles(n, count, seed, lo=240.0, hi=520.0):
    """随机气泡"啵啵"（酸液用）"""
    r = np.random.default_rng(seed)
    out = np.zeros(n)
    for _ in range(count):
        start = int(r.uniform(0, n * 0.75))
        dur = int(r.uniform(0.015, 0.045) * SR)
        if start + dur >= n:
            continue
        f = r.uniform(lo, hi)
        seg = np.sin(2.0 * np.pi * f * np.arange(dur) / SR) * np.exp(-np.arange(dur) / (0.008 * SR))
        out[start:start + dur] += seg * 0.5
    return out


def norm(x, peak=0.85):
    m = np.max(np.abs(x)) + 1e-9
    return x / m * peak


def save(name, x, peak=0.85):
    sf.write(os.path.join(OUT, name), norm(x, peak).astype(np.float32), SR)
    print("  wrote", name, "%.2fs" % (len(x) / SR))


# ---------- 枪声（区分度表：rifle 中低频 / smg 轻快高频） ----------

def gun_shot(f0, tau_body, tau_crack, crack_hi, dur, seed, body_gain=1.2):
    n = int(dur * SR)
    crack = noise(n, seed) * env_exp(n, tau_crack)
    body = sine(f0, n) * env_exp(n, tau_body) * body_gain
    mid = band(noise(n, seed + 1), 300.0, 1500.0) * env_exp(n, 0.02) * 0.6
    x = crack + body + mid
    x = band(x, 60.0, crack_hi)
    x = np.tanh(x * 2.2)  # 软削波：加"砰"的冲击感
    return x


def synth_guns():
    print("[枪声] rifle_fire / smg_fire（正式替换占位）")
    for i, f0 in enumerate([100.0, 104.0, 108.0], start=1):
        save("sfx_weapon_rifle_fire_%02d.ogg" % i, gun_shot(f0, 0.06, 0.012, 2400.0, 0.32, 10 + i, 1.3))
    for i, f0 in enumerate([155.0, 160.0, 166.0], start=1):
        save("sfx_weapon_smg_fire_%02d.ogg" % i, gun_shot(f0, 0.042, 0.009, 4800.0, 0.20, 20 + i, 0.9))


# ---------- 玩家拟声 ----------

def synth_player():
    print("[玩家] jump / land / down / die / revive / roll")
    # 跳跃：whoosh（噪声上扫 + 高频带通）
    n = int(0.25 * SR)
    x = band(noise(n, 31), 300.0, 3500.0) * env_exp(n, 0.09) + chirp_sine(500.0, 1400.0, n) * env_exp(n, 0.12) * 0.3
    save("sfx_player_jump_01.ogg", x)
    # 落地：低频 thud（两变体）
    for i, f in enumerate([68.0, 74.0], start=1):
        n = int(0.4 * SR)
        x = sine(f, n) * env_exp(n, 0.09) * 1.4 + band(noise(n, 40 + i), 100.0, 500.0) * env_exp(n, 0.02) * 0.5 \
            + sine(f * 0.62, n) * env_exp(n, 0.12) * 0.7
        save("sfx_player_land_%02d.ogg" % i, x)
    # 倒地：重 thud + 闷哼（拟声非真人）
    n = int(0.8 * SR)
    thud = sine(55.0, n) * env_exp(n, 0.1) * 1.5 + band(noise(n, 50), 80.0, 400.0) * env_exp(n, 0.03) * 0.6
    grunt = saw(110.0, int(0.5 * SR)) * env_exp(int(0.5 * SR), 0.22) * 0.28
    grunt = np.pad(grunt, (int(0.08 * SR), 0))
    x = thud + np.pad(grunt, (0, max(0, n - len(grunt))))[:n]
    save("sfx_player_down_01.ogg", x)
    # 死亡：叹息滑音向下 + 气息（避免真人惨叫，清单 §2.2 备注）
    n = int(1.1 * SR)
    sigh = saw(300.0, n) * env_exp(n, 0.5) * 0.5
    breath = band(noise(n, 51), 200.0, 1200.0) * env_exp(n, 0.6) * 0.3
    low = sine(50.0, n) * env_exp(n, 0.7) * 0.4
    x = np.tanh((sigh + breath + low) * 1.4)
    save("sfx_player_die_01.ogg", x)
    # 救援：深呼吸气声（弱-强-弱包络 + 上滑）
    n = int(0.9 * SR)
    en = np.sin(np.pi * t(n) / (n / SR)) ** 1.5
    x = band(noise(n, 52), 400.0, 2500.0) * en * 0.6 + chirp_sine(220.0, 430.0, n) * en * 0.2
    save("sfx_player_revive_01.ogg", x)
    # 翻滚：滚动摩擦（波动包络 + 收尾小 thud）
    n = int(0.7 * SR)
    roll = band(noise(n, 53), 150.0, 900.0) * (1.0 + 0.8 * np.sin(2.0 * np.pi * 11.0 * t(n))) * env_exp(n, 0.35)
    end = np.pad(sine(60.0, int(0.12 * SR)) * env_exp(int(0.12 * SR), 0.05) * 0.6, (0, max(0, n - int(0.12 * SR))))
    save("sfx_player_roll_01.ogg", roll + end[:n])


# ---------- 特感（哥布林/丧尸） ----------

def synth_specials():
    print("[特感] charge_windup / charger_hit / charger_death / spit_windup / acid_land / spitter_death / attack_hint")
    # 冲撞蓄力：渐强咆哮下滑 + 失真
    n = int(1.3 * SR)
    r = env_rise(n)
    x = np.tanh((saw(90.0, n) * r * 0.8 + band(noise(n, 60), 60.0, 600.0) * r * 0.4) * 3.0)
    save("sfx_charge_windup_01.ogg", x)
    # 冲撞命中：重撞击
    n = int(0.5 * SR)
    x = sine(55.0, n) * env_exp(n, 0.07) * 1.6 + band(noise(n, 61), 100.0, 800.0) * env_exp(n, 0.015) * 0.7 \
        + band(noise(n, 62), 2000.0, 6000.0) * env_exp(n, 0.01) * 0.3
    save("sfx_charger_hit_01.ogg", x)
    # 冲撞死亡：哀嚎下滑 + 收尾撞击
    n = int(1.0 * SR)
    x = saw(240.0, n) * env_exp(n, 0.45) * 0.6 + band(noise(n, 63), 100.0, 900.0) * env_exp(n, 0.5) * 0.3
    end = np.pad(sine(50.0, int(0.2 * SR)) * env_exp(int(0.2 * SR), 0.08) * 0.8, (0, max(0, n - int(0.2 * SR))))
    save("sfx_charger_death_01.ogg", x + end[:n])
    # 吐酸前摇：咕噜气泡渐强
    n = int(0.8 * SR)
    mod = 0.6 + 0.4 * np.sin(2.0 * np.pi * 9.0 * t(n))
    x = sine(140.0, n) * mod * env_rise(n) * 0.5 + band(noise(n, 64), 300.0, 1800.0) * env_rise(n) * 0.3 + bubbles(n, 8, 65)
    save("sfx_spit_windup_01.ogg", x)
    # 酸液落地：溅落 + 气泡
    n = int(0.45 * SR)
    x = band(noise(n, 66), 200.0, 5000.0) * env_exp(n, 0.03) * 0.8 + bubbles(n, 12, 67) + sine(90.0, n) * env_exp(n, 0.05) * 0.3
    save("sfx_acid_land_01.ogg", x)
    # 喷吐者死亡：咕噜衰减
    n = int(0.9 * SR)
    x = sine(130.0, n) * (0.5 + 0.5 * np.sin(2.0 * np.pi * 10.0 * t(n))) * env_exp(n, 0.5) * 0.7 \
        + band(noise(n, 68), 200.0, 1000.0) * env_exp(n, 0.5) * 0.3
    save("sfx_spitter_death_01.ogg", x)
    # 近战攻击预警：短促威胁低吼
    n = int(0.45 * SR)
    x = np.tanh((saw(130.0, n) * env_exp(n, 0.18) * 0.8 + band(noise(n, 69), 80.0, 700.0) * env_exp(n, 0.15) * 0.4) * 2.0)
    save("sfx_zombie_attack_hint_01.ogg", x)


# ---------- 武器举起/收起（ADS 预留） ----------

def synth_aim():
    print("[瞄准] aim_in / aim_out（金属咔哒，P3 预留）")
    n = int(0.12 * SR)
    x = band(noise(n, 70), 2500.0, 7000.0) * env_exp(n, 0.004) * 0.7 + sine(1800.0, n) * env_exp(n, 0.015) * 0.5
    save("sfx_weapon_aim_in_01.ogg", x)
    n = int(0.15 * SR)
    x = band(noise(n, 71), 1800.0, 5500.0) * env_exp(n, 0.005) * 0.6 + sine(1300.0, n) * env_exp(n, 0.02) * 0.5
    save("sfx_weapon_aim_out_01.ogg", x)


def synth_ui_fixes():
    print("[UI修复] button_press / ui_click_02 / concrete_02 峰值")
    n = int(0.09 * SR)
    x = sine(2100.0, n) * env_exp(n, 0.018) * 0.75 + band(noise(n, 81), 1200.0, 7000.0) * env_exp(n, 0.008) * 0.35
    save("sfx_button_press_01.ogg", x, 0.72)
    n = int(0.075 * SR)
    x = sine(1050.0, n) * env_exp(n, 0.014) * 0.7 + sine(1650.0, n) * env_exp(n, 0.009) * 0.3
    save("sfx_ui_click_02.ogg", x, 0.72)
    concrete_path = os.path.join(OUT, "sfx_footstep_concrete_02.ogg")
    concrete, _ = sf.read(concrete_path, dtype="float32")
    save("sfx_footstep_concrete_02.ogg", concrete, 0.72)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    synth_guns()
    synth_player()
    synth_specials()
    synth_aim()
    synth_ui_fixes()
    print("DONE ->", OUT)
