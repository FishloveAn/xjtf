import json
import math
from pathlib import Path

import numpy as np
import soundfile as sf


ROOT = Path(__file__).resolve().parents[1]
SFX_DIR = ROOT / "assets" / "audio" / "sfx"
NEW_FILENAMES = [
    "sfx_acid_land_01.ogg", "sfx_button_press_01.ogg", "sfx_charge_windup_01.ogg",
    "sfx_charger_death_01.ogg", "sfx_charger_hit_01.ogg", "sfx_door_close_01.ogg",
    "sfx_door_open_01.ogg", "sfx_door_open_02.ogg", "sfx_footstep_concrete_01.ogg",
    "sfx_footstep_concrete_02.ogg", "sfx_footstep_dirt_01.ogg", "sfx_footstep_dirt_02.ogg",
    "sfx_footstep_metal_01.ogg", "sfx_footstep_metal_02.ogg", "sfx_mechanism_01.ogg",
    "sfx_pickup_ammo_01.ogg", "sfx_pickup_health_01.ogg", "sfx_player_die_01.ogg",
    "sfx_player_down_01.ogg", "sfx_player_jump_01.ogg", "sfx_player_land_01.ogg",
    "sfx_player_land_02.ogg", "sfx_player_revive_01.ogg", "sfx_player_roll_01.ogg",
    "sfx_spit_windup_01.ogg", "sfx_spitter_death_01.ogg", "sfx_switch_toggle_01.ogg",
    "sfx_ui_cancel_01.ogg", "sfx_ui_click_01.ogg", "sfx_ui_click_02.ogg",
    "sfx_ui_confirm_01.ogg", "sfx_ui_denied_01.ogg", "sfx_weapon_aim_in_01.ogg",
    "sfx_weapon_aim_out_01.ogg", "sfx_weapon_rifle_fire_01.ogg", "sfx_weapon_rifle_fire_02.ogg",
    "sfx_weapon_rifle_fire_03.ogg", "sfx_weapon_smg_fire_01.ogg", "sfx_weapon_smg_fire_02.ogg",
    "sfx_weapon_smg_fire_03.ogg", "sfx_weapon_switch_01.ogg", "sfx_zombie_attack_hint_01.ogg",
]


def new_files() -> list[Path]:
    return [SFX_DIR / filename for filename in NEW_FILENAMES]


def db(value: float) -> float:
    return 20.0 * math.log10(max(value, 1e-9))


def analyze(path: Path) -> dict:
    samples, sample_rate = sf.read(path, always_2d=True, dtype="float32")
    mono = samples.mean(axis=1)
    peak = float(np.max(np.abs(mono)))
    rms = float(np.sqrt(np.mean(mono * mono)))
    windowed = mono * np.hanning(len(mono))
    spectrum = np.abs(np.fft.rfft(windowed)) + 1e-12
    frequencies = np.fft.rfftfreq(len(mono), 1.0 / sample_rate)
    centroid = float(np.sum(frequencies * spectrum) / np.sum(spectrum))
    low_ratio = float(np.sum(spectrum[frequencies < 250]) / np.sum(spectrum))
    high_ratio = float(np.sum(spectrum[frequencies > 2500]) / np.sum(spectrum))
    silence_ratio = float(np.mean(np.abs(mono) < 1e-4))
    clipping_ratio = float(np.mean(np.abs(mono) >= 0.999))
    checks = {
        "duration": 0.05 <= len(mono) / sample_rate <= 3.5,
        "peak": -12.0 <= db(peak) <= -0.1,
        "rms": -40.0 <= db(rms) <= -5.0,
        "silence": silence_ratio < 0.90,
        "clipping": clipping_ratio < 0.001,
        "finite": bool(np.isfinite(mono).all()),
    }
    return {
        "file": path.name,
        "duration_s": round(len(mono) / sample_rate, 3),
        "peak_dbfs": round(db(peak), 2),
        "rms_dbfs": round(db(rms), 2),
        "crest_db": round(db(peak) - db(rms), 2),
        "centroid_hz": round(centroid),
        "low_ratio": round(low_ratio, 3),
        "high_ratio": round(high_ratio, 3),
        "silence_ratio": round(silence_ratio, 3),
        "clipping_ratio": round(clipping_ratio, 5),
        "status": "PASS" if all(checks.values()) else "FAIL",
        "failed_checks": [name for name, passed in checks.items() if not passed],
    }


def main() -> int:
    files = new_files()
    rows = [analyze(path) for path in files]
    print(json.dumps({"count": len(rows), "pass": sum(row["status"] == "PASS" for row in rows), "rows": rows}, ensure_ascii=False, indent=2))
    return 0 if len(rows) == 42 and all(row["status"] == "PASS" for row in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
