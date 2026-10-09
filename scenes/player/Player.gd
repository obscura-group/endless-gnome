extends CharacterBody2D

# --- PROPRIEDADES DE MOVIMENTO ---
@export_group("Movimento Horizontal")
@export var speed: float = 300.0
@export var acceleration: float = 2400.0 # Velocidade de resposta ao acelerar

@export_group("Pulo e Gravidade")
@export var jump_velocity: float = -420.0
@export var min_jump_velocity: float = -150.0
@export var coyote_time: float = 0.15
@export var jump_buffer_time: float = 0.1
@export var jump_texture: Texture2D

@export_group("Abaixar")
## Altura da hitbox abaixado, em proporção da altura em pé (0.5 = metade)
@export_range(0.2, 0.9) var crouch_height_ratio: float = 0.5
## Sprite usado enquanto abaixado (se vazio, mantém o sprite normal)
@export var crouch_texture: Texture2D

@export_group("Rolada")
@export var roll_speed: float = 450.0
@export var roll_duration: float = 0.4
## Tempo mínimo entre uma rolada e a próxima (contado a partir do início da rolada)
@export var roll_cooldown: float = 2.0
## Sprite usado durante a rolada (se vazio, volta para o sprite normal)
@export var roll_texture: Texture2D
## Transparência do jogador durante os i-frames (feedback visual)
@export_range(0.0, 1.0) var roll_iframe_alpha: float = 0.5

# --- REFERÊNCIAS DOS NÓS ---
@onready var sprite_2d: Sprite2D = $PlayerSprite
@onready var collision_shape: CollisionShape2D = $PlayerHurtBox # <- ajuste o nome se o seu for diferente
@onready var attack_sprite: Sprite2D = $ActionSprite1
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

var roll_timer: Timer             # Duração da rolada
var roll_cooldown_timer: Timer    # Impede rolar de novo antes de passar o cooldown

# Valores originais guardados no _ready
var default_texture: Texture2D
var standing_height: float
var crouch_height: float
var standing_shape_pos_y: float


func _ready() -> void:
	# Garante que o ataque começa invisível
	if attack_sprite:
		attack_sprite.visible = false

	# Conecta o sinal do Timer via código (ou faça pela aba Nós)
	if attack_timer:
		attack_timer.timeout.connect(_on_attack_timer_timeout)

	# Duplica o shape para que mudar o tamanho não afete outras instâncias
	collision_shape.shape = collision_shape.shape.duplicate()
	standing_height = _get_shape_height()
	crouch_height = standing_height * crouch_height_ratio
	standing_shape_pos_y = collision_shape.position.y
	default_texture = sprite_2d.texture

	# Timers do roll criados por código (não precisa adicionar nós na cena)
	roll_timer = _create_timer(roll_duration, _on_roll_finished)
	roll_cooldown_timer = _create_timer(roll_cooldown)


func _physics_process(delta: float) -> void:
	apply_gravity(delta)
	handle_jump_timers(delta)
	handle_crouch()
	handle_roll_input()
	handle_jump()
	handle_horizontal_movement(delta)
	handle_attack_input()
	update_sprite_facing()
	move_and_slide()
	update_air_sprite()


# --- UTILIDADES ---
func _create_timer(wait: float, callback: Callable = Callable()) -> Timer:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = wait
	add_child(t)
	if callback.is_valid():
		t.timeout.connect(callback)
	return t


func _set_sprite_texture(tex: Texture2D) -> void:
	sprite_2d.texture = tex if tex else default_texture


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
	_set_sprite_texture(crouch_texture)


func stop_crouch() -> void:
	is_crouching = false
	_set_shape_height(standing_height)
	_set_sprite_texture(default_texture)


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
	_set_sprite_texture(roll_texture)
	sprite_2d.modulate.a = roll_iframe_alpha


func _on_roll_finished() -> void:
	is_rolling = false
	is_invulnerable = false # i-frames desligados
	sprite_2d.modulate.a = 1.0
	# Volta para o sprite abaixado; se o jogador soltou "baixo", handle_crouch() o levanta
	_set_sprite_texture(crouch_texture)


# --- DANO (exemplo de uso dos i-frames) ---
func take_damage(amount: int) -> void:
	if is_invulnerable:
		return
	# TODO: aplicar o dano de verdade aqui
	print("Jogador levou ", amount, " de dano")


# --- LÓGICA DE ATAQUE / AÇÃO ---
func handle_attack_input() -> void:
	# Ativa ao apertar a tecla configurada (pode usar "ui_accept", "ui_select" ou criar "attack")
	if Input.is_action_just_pressed("Acao1") and not is_attacking and not is_rolling:
		perform_attack()


func perform_attack() -> void:
	is_attacking = true
	attack_sprite.visible = true
	attack_timer.start()

	# Opcional: Adicionar um pequeno efeito visual com Tween (ex: escala rápida)
	var tween = create_tween()
	attack_sprite.scale = Vector2(0.5, 0.5)
	tween.tween_property(attack_sprite, "scale", Vector2(1.2, 1.2), 0.1)


func _on_attack_timer_timeout() -> void:
	is_attacking = false
	attack_sprite.visible = false


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
	# Não pula abaixado nem rolando
	if jump_buffer_timer > 0.0 and coyote_timer > 0.0 and not is_crouching and not is_rolling:
		velocity.y = jump_velocity
		jump_buffer_timer = 0.0
		coyote_timer = 0.0

	if Input.is_action_just_released("ui_accept") and velocity.y < min_jump_velocity:
		velocity.y = min_jump_velocity

func update_air_sprite() -> void:
	if is_crouching or is_rolling:
		return

	if is_on_floor():
		_set_sprite_texture(default_texture)
	else:
		_set_sprite_texture(jump_texture)

func handle_horizontal_movement(delta: float) -> void:
	# Durante a rolada o jogador só vai pra frente, ignorando o input
	if is_rolling:
		velocity.x = roll_direction * roll_speed
		return

	# Abaixado fica parado (ainda pode virar de lado para escolher a direção da rolada)
	if is_crouching:
		velocity.x = 0.0
		return

	var direction := Input.get_axis("ui_left", "ui_right")
	if direction != 0.0:
		velocity.x = direction * speed
	else:
		velocity.x = 0.0


func update_sprite_facing() -> void:
	# Não vira no meio da rolada
	if is_rolling:
		return

	var direction := Input.get_axis("ui_left", "ui_right")

	if direction > 0.0:
		facing = 1
		sprite_2d.flip_h = false
		# Reposiciona o ataque para a direita
		attack_sprite.position.x = abs(attack_sprite.position.x)
		attack_sprite.flip_h = false
	elif direction < 0.0:
		facing = -1
		sprite_2d.flip_h = true
		# Reposiciona o ataque para a esquerda
		attack_sprite.position.x = -abs(attack_sprite.position.x)
		attack_sprite.flip_h = true
