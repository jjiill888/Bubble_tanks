class_name PlayerPalette
extends RefCounted

static var _PALETTES := {
	"blue": {
		"turret_body": Color(0.55, 0.83, 1.0, 1.0),
		"turret_body_rim": Color(0.2, 0.6, 0.92, 1.0),
		"turret_ring": Color(0.35, 0.72, 0.97, 0.55),
		"turret_core": Color(0.15, 0.55, 0.9, 1.0),
		"turret_highlight": Color(1.0, 1.0, 1.0, 0.28),
		"barrel_main": Color(0.35, 0.72, 0.95, 1.0),
		"barrel_rim": Color(0.2, 0.55, 0.85, 1.0),
		"muzzle_main": Color(0.25, 0.65, 0.9, 1.0),
		"muzzle_rim": Color(0.15, 0.5, 0.8, 1.0),
		"bullet_main": Color(0.55, 0.88, 1.0, 0.95),
		"bullet_rim": Color(0.25, 0.65, 0.92, 1.0),
		"bullet_highlight": Color(1.0, 1.0, 1.0, 0.45),
	},
	"red": {
		"turret_body": Color(1.0, 0.63, 0.63, 1.0),
		"turret_body_rim": Color(0.88, 0.24, 0.24, 1.0),
		"turret_ring": Color(0.98, 0.42, 0.42, 0.55),
		"turret_core": Color(0.78, 0.16, 0.16, 1.0),
		"turret_highlight": Color(1.0, 1.0, 1.0, 0.28),
		"barrel_main": Color(0.96, 0.48, 0.48, 1.0),
		"barrel_rim": Color(0.82, 0.22, 0.22, 1.0),
		"muzzle_main": Color(0.9, 0.34, 0.34, 1.0),
		"muzzle_rim": Color(0.72, 0.16, 0.16, 1.0),
		"bullet_main": Color(1.0, 0.7, 0.7, 0.95),
		"bullet_rim": Color(0.88, 0.28, 0.28, 1.0),
		"bullet_highlight": Color(1.0, 1.0, 1.0, 0.45),
	},
	"white": {
		"turret_body": Color(0.97, 0.99, 1.0, 1.0),
		"turret_body_rim": Color(0.78, 0.84, 0.92, 1.0),
		"turret_ring": Color(0.86, 0.91, 0.98, 0.52),
		"turret_core": Color(0.72, 0.82, 0.95, 1.0),
		"turret_highlight": Color(1.0, 1.0, 1.0, 0.32),
		"barrel_main": Color(0.9, 0.95, 1.0, 1.0),
		"barrel_rim": Color(0.72, 0.8, 0.9, 1.0),
		"muzzle_main": Color(0.82, 0.9, 0.98, 1.0),
		"muzzle_rim": Color(0.63, 0.73, 0.86, 1.0),
		"bullet_main": Color(1.0, 1.0, 1.0, 0.95),
		"bullet_rim": Color(0.76, 0.84, 0.94, 1.0),
		"bullet_highlight": Color(1.0, 1.0, 1.0, 0.5),
	},
	"green": {
		"turret_body": Color(0.67, 1.0, 0.75, 1.0),
		"turret_body_rim": Color(0.24, 0.78, 0.42, 1.0),
		"turret_ring": Color(0.45, 0.9, 0.56, 0.55),
		"turret_core": Color(0.16, 0.64, 0.3, 1.0),
		"turret_highlight": Color(1.0, 1.0, 1.0, 0.28),
		"barrel_main": Color(0.44, 0.86, 0.55, 1.0),
		"barrel_rim": Color(0.2, 0.7, 0.36, 1.0),
		"muzzle_main": Color(0.32, 0.78, 0.44, 1.0),
		"muzzle_rim": Color(0.14, 0.58, 0.28, 1.0),
		"bullet_main": Color(0.72, 1.0, 0.78, 0.95),
		"bullet_rim": Color(0.28, 0.82, 0.4, 1.0),
		"bullet_highlight": Color(1.0, 1.0, 1.0, 0.45),
	},
}

static func get_palette_keys() -> Array[String]:
	var keys: Array[String] = []
	for key in ["blue", "red", "white", "green"]:
		keys.append(key)
	return keys

static func get_palette(color_key: String) -> Dictionary:
	var resolved_key := color_key if _PALETTES.has(color_key) else "blue"
	return (_PALETTES[resolved_key] as Dictionary).duplicate(true)