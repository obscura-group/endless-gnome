extends CharacterBody2D

# --- ANIMAÇÃO / VISUAL ---
enum PlayerState {
	attack,
	duck,
	idle,
	jump,
	rolling,
	walk,
}

const ANIMATION_NAMES := {
	PlayerState.attack: &"attack",
	PlayerState.duck: &"duck",
	PlayerState.idle: &"idle",
	PlayerState.jump: &"jump",
	PlayerState.rolling: &"rolling",
	PlayerState.walk: &"walk",
}

@export var animation_switch: AnimatedSprite2D

# --- PROPRIEDADES DE MOVIMENTO ---
var direction = 0
@export_group("Movimento Horizontal")
@export var speed: float = 300.0
@export var acceleration: float = 2400.0 # Velocidade de resposta ao acelerar


@export_group("Pulo e Gravidade")
@export var jump_velocity: float = -420.0
@export var min_jump_velocity: float = -150.0
@export var coyote_time: float = 0.15
@export var jump_buffer_time: float = 0.1

@export_group("Abaixar")
@export_range(0.2, 0.9) var crouch_height_ratio: float = 0.5

@export_group("Rolada")
@export var roll_speed: float = 450.0
@export var roll_duration: float = 0.4
@export var roll_cooldown: float = 2.0
@export_range(0.0, 1.0) var roll_iframe_alpha: float = 0.5

# --- REFERÊNCIAS DOS NÓS ---
@onready var collision_shape: CollisionShape2D = $PlayerHurtBox # <- ajuste o nome se o seu for diferente
@onready var attack_timer: Timer = $ActionCooldown1

# Timers Internos
var coyote_timer: float = 0.0
var jump_buffer_timer: float = 0.0
var is_attacking: bool = false

# Estado de abaixar / rolar
var is_crouching: bool = false
var is_rolling: bool = false
var is_invulnerable: bool = false # Use isso no seu sistema de dano (veja take_damage)
var facing: int = 1               # 1 = direita, -1 = esquerda
var roll_direction: int = 1

var roll_timer: Timer             # Duração da Rolada
var roll_cooldown_timer: Timer    # Cooldown da Rolagem

# Valores originais guardados no _ready
var default_texture: Texture2D
var standing_height: float
var crouch_height: float
var standing_shape_pos_y: float

# Última animação enviada ao sprite (evita reiniciar a animação a cada frame)
var last_animation: StringName = &""


func _ready() -> void:
	collision_shape.shape = collision_shape.shape.duplicate()
	standing_height = _get_shape_height()
	crouch_height = standing_height * crouch_height_ratio
	standing_shape_pos_y = collision_shape.position.y

	roll_timer = _create_timer(roll_duration, _on_roll_finished)
	roll_cooldown_timer = _create_timer(roll_cooldown)

	_setup_animations()


func _physics_process(delta: float) -> void:
	apply_gravity(delta)
	handle_jump_timers(delta)
	handle_crouch()
	handle_roll_input()
	handle_attack_input()
	handle_jump()
	handle_horizontal_movement(delta)
	update_sprite_facing()
	move_and_slide()
	update_animation() 

# --- UTILIDADES ---
func _create_timer(wait: float, callback: Callable = Callable()) -> Timer:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = wait
	add_child(t)
	if callback.is_valid():
		t.timeout.connect(callback)
	return t

# --- ANIMAÇÕES ---
func _setup_animations() -> void:
	# O cooldown do ataque precisa ser one_shot para is_stopped() funcionar
	attack_timer.one_shot = true

	# Se esqueceu de arrastar o nó no Inspector, tenta achar um AnimatedSprite2D filho
	if animation_switch == null:
		animation_switch = get_node_or_null("AnimatedSprite2D")
	if animation_switch == null or animation_switch.sprite_frames == null:
		push_warning("animation_switch sem AnimatedSprite2D/SpriteFrames: atribua o nó no Inspector.")
		return

	# O ataque termina quando a animação acaba, então ela não pode ficar em loop
	var attack_anim: StringName = ANIMATION_NAMES[PlayerState.attack]
	if animation_switch.sprite_frames.has_animation(attack_anim):
		animation_switch.sprite_frames.set_animation_loop(attack_anim, false)

	animation_switch.animation_finished.connect(_on_animation_finished)


func get_current_state() -> PlayerState:
	# A ordem importa: o primeiro que for verdadeiro vence
	if is_rolling:
		return PlayerState.rolling
	if is_attacking:
		return PlayerState.attack
	if is_crouching:
		return PlayerState.duck
	if not is_on_floor():
		return PlayerState.jump
	if absf(velocity.x) > 0.0:
		return PlayerState.walk
	return PlayerState.idle


func update_animation() -> void:
	if animation_switch == null or animation_switch.sprite_frames == null:
		return

	var anim_name: StringName = ANIMATION_NAMES[get_current_state()]
	if not animation_switch.sprite_frames.has_animation(anim_name):
		push_warning("Animação não encontrada no SpriteFrames: " + String(anim_name))
		return

	# Só troca quando muda, senão a animação reiniciaria todo frame
	if anim_name != last_animation:
		animation_switch.play(anim_name)
		last_animation = anim_name


func _on_animation_finished() -> void:
	if animation_switch.animation == ANIMATION_NAMES[PlayerState.attack]:
		is_attacking = false

# --- HITBOX ---
func _get_shape_height() -> float:
	var shape = collision_shape.shape
	if shape is RectangleShape2D:
		return shape.size.y
	if shape is CapsuleShape2D:
		return shape.height
	push_warning("Use RectangleShape2D ou CapsuleShape2D no CollisionShape2D do jogador.")
	return 0.0


func _set_shape_height(h: float) -> void:
	var shape = collision_shape.shape
	if shape is RectangleShape2D:
		shape.size.y = h
	elif shape is CapsuleShape2D:
		shape.height = h
	# Mantém os "pés" no mesmo lugar: a hitbox encolhe por cima
	collision_shape.position.y = standing_shape_pos_y + (standing_height - h) / 2.0


func can_stand_up() -> bool:
	# Testa se existe teto no espaço que a hitbox em pé ocuparia
	var diff := standing_height - crouch_height
	return not test_move(global_transform, Vector2(0.0, -diff))


# --- ABAIXAR ---
func handle_crouch() -> void:
	if is_rolling:
		return

	var wants_crouch := Input.is_action_pressed("ui_down") and is_on_floor()

	if wants_crouch and not is_crouching:
		start_crouch()
	elif not wants_crouch and is_crouching and can_stand_up():
		stop_crouch()


func start_crouch() -> void:
	is_crouching = true
	_set_shape_height(crouch_height)



func stop_crouch() -> void:
	is_crouching = false
	_set_shape_height(standing_height)



# --- ROLADA ---
func handle_roll_input() -> void:
	if Input.is_action_just_pressed("Roll") \
			and is_crouching \
			and is_on_floor() \
			and not is_rolling \
			and roll_cooldown_timer.is_stopped():
		start_roll()


func start_roll() -> void:
	is_rolling = true
	is_invulnerable = true # i-frames ligados
	roll_direction = facing
	roll_timer.start()
	roll_cooldown_timer.start() # Só libera outra rolada depois do cooldown


func _on_roll_finished() -> void:
	is_rolling = false
	is_invulnerable = false # i-frames desligados



# --- ATAQUE ---
func handle_attack_input() -> void:
	if Input.is_action_just_pressed("Acao1") \
			and not is_attacking \
			and not is_rolling \
			and not is_crouching \
			and attack_timer.is_stopped():
		start_attack()


func start_attack() -> void:
	is_attacking = true
	attack_timer.start() # Cooldown do ataque (tempo configurado no nó ActionCooldown1)
	last_animation = &"" # Força a animação de ataque a recomeçar do primeiro frame
	# O fim do ataque (is_attacking = false) vem de _on_animation_finished


# --- DANO (exemplo de uso dos i-frames) ---
func take_damage(amount: int) -> void:
	if is_invulnerable:
		return
	# TODO: aplicar o dano de verdade aqui 
	print("Jogador levou ", amount, " de dano")


# --- MOVIMENTO E FÍSICA ---
func apply_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity += get_gravity() * delta


func handle_jump_timers(delta: float) -> void:
	if is_on_floor():
		coyote_timer = coyote_time
	else:
		coyote_timer -= delta

	if Input.is_action_just_pressed("ui_accept"):
		jump_buffer_timer = jump_buffer_time
	else:
		jump_buffer_timer -= delta


func handle_jump() -> void:
	# Impede Pulos e Ataques
	if jump_buffer_timer > 0.0 and coyote_timer > 0.0 and not is_crouching and not is_rolling:
		velocity.y = jump_velocity
		jump_buffer_timer = 0.0
		coyote_timer = 0.0

	if Input.is_action_just_released("ui_accept") and velocity.y < min_jump_velocity:
		velocity.y = min_jump_velocity


func handle_horizontal_movement(delta: float) -> void:
	if is_rolling:
		velocity.x = roll_direction * roll_speed
		return

	if is_crouching:
		velocity.x = 0.0
		return

	var direction := Input.get_axis("ui_left", "ui_right")
	if direction != 0.0:
		velocity.x = direction * speed
	else:
		velocity.x = 0.0

# 👹

func update_sprite_facing() -> void:
	# Não vira no meio da rolada
	if is_rolling:
		return

	var direction := Input.get_axis("ui_left", "ui_right")
	if direction != 0.0:
		facing = 1 if direction > 0.0 else -1

	# Considera que os sprites foram desenhados virados para a direita
	if animation_switch != null:
		animation_switch.flip_h = facing == -1
