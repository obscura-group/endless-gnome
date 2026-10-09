extends Area2D

# Void Respawn Position
@export var target_y_position: float = 100

# Keep Falling Speed (true or false)
@export var keep_velocity_x: bool = true


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(body: Node2D) -> void:
	# Check if its an Entity
	if body is CharacterBody2D:
		# Respawns said Entity on the map
		body.global_position.y = target_y_position
		# Nullifies Y velocity
		body.velocity.y = 0.0
