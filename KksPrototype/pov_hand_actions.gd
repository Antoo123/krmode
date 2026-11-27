extends RefCounted

const Contact := preload("res://hand_contact_motion.gd")
const Preset := preload("res://hand_animation_preset.gd")
const ACTIONS := {
	"stroke_thigh": ["Thigh", "thigh", "L", "stroke", 0.05],
	"stroke_belly": ["Belly", "belly", "R", "stroke", 0.04],
	"take_hand": ["Hand", "hand", "L", "hold", 0.0],
	"stroke_left_side": ["Sides", "side", "L", "stroke", 0.045],
	"stroke_right_side": ["Sides", "side", "R", "stroke", 0.045],
	"hold_left_side": ["Sides", "side", "L", "hold", 0.0],
	"hold_right_side": ["Sides", "side", "R", "hold", 0.0],
	"rub_side": ["Sides", "side", "L", "rub", 0.036],
	"stroke_left_foot": ["Feet", "foot", "L", "stroke", 0.032],
	"stroke_right_foot": ["Feet", "foot", "R", "stroke", 0.032],
	"hold_left_foot": ["Feet", "foot", "L", "hold", 0.0],
	"hold_right_foot": ["Feet", "foot", "R", "hold", 0.0],
	"stroke_ankle": ["Feet", "ankle", "L", "stroke", 0.026],
	"pat_head": ["Crown", "crown", "L", "pat", 0.030],
	"stroke_hair": ["Crown", "crown", "L", "stroke", 0.054],
	"hold_head": ["Crown", "crown", "L", "hold", 0.0],
	"gentle_head_touch": ["Crown", "crown", "L", "touch", 0.016],
	"chin_lift": ["Face", "chin", "L", "lift", 0.036],
	"touch_cheek": ["Face", "cheek", "L", "pinch", 0.019],
}
const BONES := {"side": "cf_j_spine01", "foot": "cf_j_foot_", "ankle": "cf_j_leg03_", "crown": "cf_j_head",
	"chin": "cf_J_ChinTip_Base", "cheek": "cf_j_head"}


static func make(action: String, side: String) -> Dictionary:
	if not ACTIONS.has(action):
		return {}
	var row: Array = ACTIONS[action]
	var kind: String = row[1]
	if kind not in BONES:
		var existing := Preset.read(Preset.EXAMPLES.path_join(action + ".json"))
		if not existing.is_empty():
			existing.asset = "p_hand" + side
		return existing
	var bone: String = BONES[kind]
	if bone.ends_with("_"):
		bone += String(row[2])
	var preset := Preset.create("p_hand" + side, 0, bone)
	preset.name = action
	preset.action = action
	var target: String = ("R" if side == "L" else "L") if kind == "cheek" else row[2]
	preset.contact = {"kind": kind, "side": target, "amplitude": 1.0, "speed": 1.0, "approach": 0.38, "release": 0.34}
	preset.bone = Contact.bone_name(preset.contact)
	preset.duration = 2.15
	preset.loop = row[3] != "touch" and row[3] != "hold"
	preset.finger_layer = -1
	var distance: float = row[4]
	var points := [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	match String(row[3]):
		"stroke":
			points = [Vector3(0, -distance, 0), Vector3.ZERO, Vector3(0, distance, 0), Vector3(0, -distance, 0)]
		"rub":
			points = [Vector3(0, -distance, 0), Vector3(0.016, 0, 0), Vector3(0, distance, 0), Vector3(0, -distance, 0)]
		"lift":
			preset.loop = false
			points = [Vector3.ZERO, Vector3(0, distance * 0.25, 0), Vector3(0, distance * 0.72, 0), Vector3(0, distance, 0)]
		"pinch":
			preset.loop = false
			var direction := 1.0 if target == "L" else -1.0
			points = [Vector3.ZERO, Vector3(direction * distance * 0.25, 0, 0),
				Vector3(direction * distance * 0.7, 0, 0), Vector3(direction * distance, 0, 0)]
		"pat":
			points[1] = Vector3(0, 0, distance)
		"touch":
			preset.duration = 1.10
			preset.contact.release = 0.27
			points[0].z = distance
			points[3].z = distance
	var last := float(preset.duration) - float(preset.contact.release)
	for i in points.size():
		preset.keys.append(Preset.frame(lerpf(preset.contact.approach, last, i / 3.0), Transform3D(Basis.IDENTITY, points[i])))
	return preset
