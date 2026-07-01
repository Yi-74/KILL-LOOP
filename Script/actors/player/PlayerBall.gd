extends RigidBody2D

signal speed_updated(speed: float)
signal energy_updated(current_energy: float)
signal combo_updated(combo_count: int)
signal combo_lost()
signal launch_failed()
signal wall_bounced(bounce_count: int, is_combo_lost: bool, impact_position: Vector2)
signal enemy_killed()
signal energy_bar_1_filled()
signal energy_bar_2_filled()
signal energy_bar_3_filled()
signal player_died()

@export_group("Launch Power", "launch_")
@export var launch_multiplier: float = 10.0 #发射力度
@export var kill_threshold: float = 1500.0 #击杀速度
@export var default_max_speed: float = 4000.0 # 记录初始速度上限
@export var slow_mo_scale: float = 0.1 #子弹时间
@export_group("Energy System")
@export var energy_per_kill: float = 28.0   # 击杀敌人增加的能量
@export var energy_per_bounce: float = 35.0 # 反弹墙壁增加的能量
@export var energy_drain_per_second: float = 80.0 # 举例：每秒消耗**点能量
@export_group("Combo System")
@export var combo_max_bounces: int = 4       # 最大反弹容忍次数
@export var combo_speed_bonus: float = 250.0  # 每次连击成功，速度上限增加值
@export var combo_energy_bonus: float = 12.0 # 每次连击成功，额外能量奖励
@export_group("Aim Arrow")
@export var arrow_max_distance: float = 120.0  # 箭头离玩家的最远距离
@export var arrow_max_scale: float = 1.0      # 箭头的最大缩放比例
@export var arrow_dash_distance: float = 300.0 # 发射时，残影箭头前冲的距离
@export var arrow_dash_time: float = 0.3       # 箭头前冲并消散的时间
@export_group("Burst Speed")
@export var burst_multiplier: float = 2.0      # 爆发初始速度的倍率 (比如设为2，就是起步速度翻倍)
@export var burst_damp: float = 1.3           # 爆发时的“刹车阻力”，值越大，衰减到正常速度越快
@export var burst_duration: float = 0.2        # 爆发感持续时间 (与阻力恢复到0的时间挂钩)
@export_group("Aiming Camera Zoom")
@export var aim_zoom_x: float = 1.062  # 瞄准时，水平方向(左右)的拉伸放大倍数
@export var aim_zoom_y: float = 1.049  # 瞄准时，垂直方向(上下)的拉伸放大倍数
@export_group("Aiming Blur Effect")
@export var max_blur_strength: float = 0.03  # 最大模糊程度
@export var blur_charge_time: float = 3    # 达到最大模糊需要的时间(秒)

@onready var line_2d: Line2D = $Line2D
@onready var kill_area: Area2D = $Area2D
@onready var death_audio_player: AudioStreamPlayer = $DeathAudioPlayer
@onready var visual_sprite: Sprite2D = $Sprite2D
@onready var trail_node: Line2D = $TrailwithLine2D
@onready var aim_arrow: Sprite2D = $AimArrow
@onready var slow_mo_audio: AudioStreamPlayer = $SlowMoAudioPlayer
@onready var launch_audio: AudioStreamPlayer = $LaunchAudioPlayer
@onready var cancel_audio: AudioStreamPlayer = $CancelAudioPlayer
@onready var death_effect: ColorRect = get_node("/root/Main_tscn/DeathInversionEffect")
@onready var spawner = get_node("/root/Main_tscn/EnemySpawner") 
@onready var camera: Camera2D = get_node("/root/Main_tscn/Camera2D")
@onready var crt_effect: ColorRect = get_node("/root/GlobalEffects/ColorRect") # 获取 CRT 特效
@onready var radial_blur_effect: ColorRect = get_node("/root/GlobalEffects/RadialBlurEffect")

var is_dead: bool = false
var is_aiming: bool = false
var current_energy: float = 300.0 # 初始能量为满
var drag_start_position_screen: Vector2 = Vector2.ZERO
var velocity_before_impact: Vector2 = Vector2.ZERO
var current_combo: int = 0
var bounces_since_last_kill: int = 0
var has_killed_in_combo: bool = false
var current_max_speed: float = 0.0
var line_color_normal: Color = Color.WHITE
var line_color_low_energy: Color = Color("ff3b30") # 这是我们之前用过的那个红色
var line_color_tween: Tween # 用来控制颜色过渡的 Tween
var camera_zoom_tween: Tween
var blur_tween: Tween


func _ready() -> void:
	contact_monitor = true
	max_contacts_reported = 5
	sleeping = false
	# 连接两个信号，分别处理不同逻辑
	kill_area.area_entered.connect(_on_kill_area_entered)
	body_entered.connect(_on_body_entered)
	current_max_speed = default_max_speed
	speed_updated.connect(on_speed_updated)




func _input(event: InputEvent) -> void:
	if is_dead: return

	# ... (右键取消的逻辑不变) ...
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.is_pressed():
		_cancel_aiming()
		return # 处理完右键后，直接结束本次输入处理
		
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		
		if event.is_pressed(): # --- 鼠标按下 ---
			if not is_aiming:
				# --- 【核心修正】移除能量检查，无条件进入子弹时间！ ---
				is_aiming = true
				Engine.time_scale = slow_mo_scale
				
				# ... (其他进入瞄准的逻辑保持不变)
				drag_start_position_screen = event.position
				line_2d.clear_points()
				line_2d.add_point(Vector2.ZERO); line_2d.add_point(Vector2.ZERO)
				if is_instance_valid(slow_mo_audio):
					slow_mo_audio.play()
				if has_method("fade_slow_mo_filter"):
					fade_slow_mo_filter(true)
					
				# -------------------------------------------------------------
				# --- 【新增】进入子弹时间，镜头平滑拉近到 1.15 倍！ ---
				tween_camera_zoom(Vector2(aim_zoom_x, aim_zoom_y), 0.2)
				fade_radial_blur(true)  # 【新增这一行！开始慢慢模糊】
				# -------------------------------------------------------------
		
		else: # --- 鼠标松开 ---
			if is_aiming:
				# 无论发射成功与否，瞄准都结束了，所以先执行所有“收尾”工作
				is_aiming = false
				Engine.time_scale = 1.0
				line_2d.clear_points()
				if is_instance_valid(slow_mo_audio):
					slow_mo_audio.stop()
				if has_method("fade_slow_mo_filter"):
					fade_slow_mo_filter(false)

				# -------------------------------------------------------------
				# --- 【新增】退出子弹时间，镜头平滑恢复到 1.0 倍！ ---
				tween_camera_zoom(Vector2(1.0, 1.0), 0.2)
				fade_radial_blur(false) # 【新增这一行！迅速恢复清晰】
				# -------------------------------------------------------------

				# --- 【门禁被移动到了这里】---
				# 只有在尝试发射时，才检查能量
				if current_energy < 100.0:
					print("能量不足！无法发射！")
					if is_instance_valid(cancel_audio):
						cancel_audio.play()
					launch_failed.emit()
					
					# --- 【新增】触发成就！只要发射失败就给成就 ---
					if SteamManager.is_steam_initialized:
						SteamManager.unlock_achievement("ACH_MISC_ENERGY_EMPTY")
						
					return # 能量不足，发射失败并结束

				# --- 如果能量足够，则执行发射 ---
				if is_instance_valid(launch_audio):
					launch_audio.play()
				
				_update_energy(current_energy - 100.0)

				var screen_drag_vector = event.position - drag_start_position_screen
				var launch_magnitude = screen_drag_vector.length() * launch_multiplier
				var mouse_world_pos = get_global_mouse_position()
				var world_direction_vector = (mouse_world_pos - global_position).normalized()
				linear_velocity = -world_direction_vector * launch_magnitude

				if linear_velocity.length_squared() > kill_threshold * kill_threshold:
					set_collision_mask_value(2, false)
				else:
					set_collision_mask_value(2, true)
				
				# --- 如果能量足够，则执行发射 ---
				if is_instance_valid(launch_audio):
					launch_audio.play()
				
				_update_energy(current_energy - 100.0)

				var final_launch_dir = -world_direction_vector
				# -------------------------------------------------------------
				# --- 【核心修改】爆发速度与平滑刹车 ---
				# -------------------------------------------------------------
				# 1. 赋予极高的初始速度 (基础速度 × 爆发倍率)
				linear_velocity = final_launch_dir * (launch_magnitude * burst_multiplier)
				
				# 2. 赋予极高的空气阻力 (Linear Damp)
				linear_damp = burst_damp
				
				# 3. 使用 Tween 将阻力平滑降回 0 (或您的默认值)
				# 这样就完美模拟了一开始极快，然后顺滑回落到正常速度的推背感！
				var damp_tween = create_tween()
				damp_tween.tween_property(self, "linear_damp", 0.0, burst_duration).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

				# -------------------------------------------------------------
				# --- 【新增】箭头前冲脱离残影 ---
				# -------------------------------------------------------------
				if aim_arrow.visible:
					# 神级操作：直接克隆一个箭头！
					var arrow_ghost = aim_arrow.duplicate()
					# 把克隆的残影添加到世界里，这样它就不会跟着玩家球跑了
					get_parent().add_child(arrow_ghost)
					
					# 对齐世界坐标
					arrow_ghost.global_position = aim_arrow.global_position
					arrow_ghost.global_rotation = aim_arrow.global_rotation
					
					# 隐藏玩家身上的本体箭头
					aim_arrow.hide()
					
					# 用 Tween 给残影做【前冲+渐隐】动画
					var ghost_tween = create_tween().set_parallel(true)
					ghost_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
					
					# a) 顺着发射方向前冲
					var dash_target_pos = arrow_ghost.global_position + final_launch_dir * arrow_dash_distance
					ghost_tween.tween_property(arrow_ghost, "global_position", dash_target_pos, arrow_dash_time)
					# b) 彻底变透明
					ghost_tween.tween_property(arrow_ghost, "modulate:a", 0.0, arrow_dash_time)
					# c) 动画结束时销毁残影垃圾
					ghost_tween.chain().tween_callback(arrow_ghost.queue_free)

				# -------------------------------------------------------------
				# (后续的关闭碰撞蒙版穿透敌人的逻辑保持不变)
				if linear_velocity.length_squared() > kill_threshold * kill_threshold:
					set_collision_mask_value(2, false)
				else:
					set_collision_mask_value(2, true)



# --- 【新增】平滑控制镜头缩放的函数 ---
func tween_camera_zoom(target_zoom: Vector2, duration: float = 0.2):
	# 确保之前我们获取过摄像机 (如果您代码里叫别的名字，请替换这里的 camera)
	if not is_instance_valid(camera): 
		return
		
	# 杀死旧动画，防止冲突
	if is_instance_valid(camera_zoom_tween):
		camera_zoom_tween.kill()
		
	camera_zoom_tween = create_tween()
	# 使用 SINE 曲线，既平滑又有略微的弹性加速感
	camera_zoom_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	
	# 动态改变摄像机的 zoom 属性
	camera_zoom_tween.tween_property(camera, "zoom", target_zoom, duration)



func _process(delta: float) -> void:
	if is_aiming:
		# ==========================================
		# 1. 画瞄准线
		# ==========================================
		var mouse_world_pos = get_global_mouse_position()
		var local_mouse_pos = to_local(mouse_world_pos)
		line_2d.set_point_position(1, local_mouse_pos)
		
		# ==========================================
		# 2. 持续消耗能量与耗尽判断
		# ==========================================
		var energy_before_drain = current_energy
		_update_energy(current_energy - (energy_drain_per_second * delta))
		
		if current_energy <= 0:
			print("能量耗尽，强制退出子弹时间！")
			# 触发成就
			if ClassDB.class_exists("SteamManager") or has_node("/root/SteamManager"):
				SteamManager.unlock_achievement("ACH_MISC_ENERGY_EMPTY")
			_cancel_aiming()
			return # 提前结束，不执行后面的逻辑了
			
		# ==========================================
		# 3. 瞄准线颜色预警
		# ==========================================
		if current_energy < 100.0:
			_tween_line_color(line_color_low_energy)
		else:
			_tween_line_color(line_color_normal)
			
		# ==========================================
		# 4. 动态箭头逻辑
		# ==========================================
		var screen_drag_vector = get_viewport().get_mouse_position() - drag_start_position_screen
		var current_pull_distance = screen_drag_vector.length()
		var drag_ratio = clamp(current_pull_distance / 300.0, 0.0, 1.0)
		
		if drag_ratio > 0.05:
			aim_arrow.show()
			var actual_launch_dir = (global_position - mouse_world_pos).normalized()
			aim_arrow.global_rotation = actual_launch_dir.angle()
			aim_arrow.global_position = global_position + actual_launch_dir * (arrow_max_distance * drag_ratio)
			
			var current_scale = arrow_max_scale * drag_ratio
			aim_arrow.scale = Vector2(current_scale, current_scale)
			aim_arrow.modulate.a = drag_ratio
		else:
			aim_arrow.hide()
			
	else:
		# ==========================================
		# 5. 【没有在瞄准时】的兜底隐藏
		# ==========================================
		if is_instance_valid(aim_arrow):
			aim_arrow.hide()



func _physics_process(delta: float) -> void:
	velocity_before_impact = linear_velocity
	if not is_aiming and linear_velocity.length_squared() < 1.0:
		if not get_collision_mask_value(2):
			set_collision_mask_value(2, true)
	if linear_velocity.length() > current_max_speed:
		linear_velocity = linear_velocity.normalized() * current_max_speed
	# 当速度慢下来时，恢复物理碰撞能力
	if not is_aiming and linear_velocity.length_squared() < 1.0:
		if not get_collision_mask_value(2): # 第2层是 enemies_solid
			set_collision_mask_value(2, true)
	# 发出信号 --- 我们用 .length() 获取当前速度的大小，并用 int() 把它变成整数，方便显示
	speed_updated.emit(int(linear_velocity.length()))




# --- 在脚本中添加这个新的辅助函数 ---
func _cancel_aiming():
	if not is_aiming: return
	is_aiming = false
	Engine.time_scale = 1.0
	line_2d.clear_points()
	if is_instance_valid(slow_mo_audio): slow_mo_audio.stop()
	if is_instance_valid(cancel_audio): cancel_audio.play()
	if has_method("fade_slow_mo_filter"): fade_slow_mo_filter(false)
	# --- 【新增】右键取消时，镜头也平滑恢复！ ---
	if has_method("tween_camera_zoom"):
		tween_camera_zoom(Vector2(1.0, 1.0), 0.2)
	fade_radial_blur(false) # 取消时也要恢复清晰
	aim_arrow.hide() # 【新增】取消瞄准时隐藏箭头




func on_speed_updated(current_speed: float):
	# 1. 调用颜色计算函数
	var target_color = get_color_for_speed(current_speed)
	
	# 2. 将计算出的颜色，应用到视觉节点上
	if is_instance_valid(visual_sprite):
		visual_sprite.modulate = target_color




func get_color_for_speed(speed: float) -> Color:
	# 【核心修正】我们现在使用 trail_node 这个变量来获取权威数据
	var low_thresh = trail_node.low_speed_threshold
	var high_thresh = trail_node.high_speed_threshold
	
	if speed <= low_thresh:
		return trail_node.low_speed_color
	elif speed < high_thresh:
		var progress = inverse_lerp(low_thresh, high_thresh, speed)
		return trail_node.low_speed_color.lerp(trail_node.mid_speed_color, progress)
	else:
		var super_speed_thresh = high_thresh + 500.0
		var progress = inverse_lerp(high_thresh, super_speed_thresh, speed)
		return trail_node.mid_speed_color.lerp(trail_node.high_speed_color, progress)



func _update_energy(new_energy: float):
	# --- 1. 记录更新前的能量值 ---
	var energy_before_update = current_energy

	# --- 2. 更新并限制能量值 (与之前相同) ---
	current_energy = clamp(new_energy, 0.0, 300.0)
	
	# --- 3. 发出常规的能量更新信号，让 UI 能量条刷新 (与之前相同) ---
	energy_updated.emit(current_energy)
	
	# -----------------------------------------------------------------
	# --- 4. 【核心】检查是否【向上】跨越了阈值 ---
	# -----------------------------------------------------------------
	# 只有在能量是【增加】的情况下，才进行检查
	if current_energy > energy_before_update:
		
		# 检查是否跨越了 100
		if energy_before_update < 100.0 and current_energy >= 100.0:
			energy_bar_1_filled.emit()
			
		# 检查是否跨越了 200
		if energy_before_update < 200.0 and current_energy >= 200.0:
			energy_bar_2_filled.emit()

		# 检查是否跨越了 300 (能量满了)
		if energy_before_update < 300.0 and current_energy >= 300.0:
			energy_bar_3_filled.emit()



func _on_kill_area_entered(area: Area2D):
	if is_dead: return
	var enemy_body = area.owner
	if velocity_before_impact.length_squared() > kill_threshold * kill_threshold:
		if enemy_body.has_method("die"):
			var impact_direction = velocity_before_impact.normalized()
			enemy_body.die(impact_direction)
			call_deferred("trigger_kill_slow_motion", 0.15, 0.2)
			enemy_killed.emit()
			
			# --- 【核心修改】在这里触发屏幕抖动！ ---
			if is_instance_valid(camera):
				camera.apply_shake(6.0)
			
			# --- 每次成功击杀，都重置“撞墙计数器” ---
			bounces_since_last_kill = 0
			enemy_killed.emit()
			
			# --- 增加 Combo ---
			current_combo += 1
			combo_updated.emit(current_combo)
			
			# 触发成就：根本停不下来！
			if current_combo >= 30:
				SteamManager.unlock_achievement("ACH_COMBO_30")

			current_max_speed = default_max_speed + (current_combo * combo_speed_bonus)
			# -----------------------------------------------------------------

			# 给予能量奖励 (这个逻辑可以保持不变，也可以同样做成累积的)
			_update_energy(current_energy + combo_energy_bonus)
			
			# 增加基础的击杀能量
			_update_energy(current_energy + energy_per_kill)
			
		# 【核心修改】通知 Spawner 加分
			spawner.add_score(enemy_body.base_score_value, current_combo, enemy_body.global_position)
			enemy_body.die(impact_direction)



func _on_body_entered(body: Node):
	if is_dead: return

	# --- 【核心修正】计算精确的近似碰撞点 ---
	
	# 1. 获取玩家碰撞体的半径 (假设是圆形)
	var player_radius = $CollisionShape2D.shape.radius * global_scale.x
	
	# 2. 获取玩家撞击墙壁时的方向
	var impact_direction = velocity_before_impact.normalized()
	
	# 3. 精确的碰撞点 ≈ 玩家的中心位置 + 沿着撞击方向延伸一个半径的距离
	var impact_position = global_position + impact_direction * player_radius

	# --- 后续的所有逻辑，都使用这个新的、更精确的 impact_position ---
	
	if body.is_in_group("enemy"):
		if velocity_before_impact.length_squared() < kill_threshold * kill_threshold:
			_player_death_sequence()
		return

	if body.is_in_group("bouncing_enemy"):
		return
			
	# 如果是墙壁
	var is_combo_lost_this_hit = false
	if not has_killed_in_combo:
		bounces_since_last_kill += 1
		if bounces_since_last_kill >= combo_max_bounces:
			is_combo_lost_this_hit = true
			
	wall_bounced.emit(bounces_since_last_kill, is_combo_lost_this_hit, impact_position)
			
	if is_combo_lost_this_hit:
		lose_combo()
	
	_update_energy(current_energy + energy_per_bounce)



func lose_combo():
	if current_combo > 0:
		current_combo = 0
		combo_updated.emit(current_combo)
		combo_lost.emit()
		
		current_max_speed = default_max_speed
	
	bounces_since_last_kill = 0 # 重置“撞墙计数器”



func trigger_kill_slow_motion(duration: float, time_scale_during_slow_mo: float = 0.2):
	var original_time_scale = Engine.time_scale
	Engine.time_scale = time_scale_during_slow_mo
	await get_tree().create_timer(duration, true, false, true).timeout
	if is_aiming:
		Engine.time_scale = slow_mo_scale
	else:
		Engine.time_scale = 1.0



func _tween_line_color(target_color: Color):
	# --- 【核心优化】 ---
	
	# 1. 检查：如果线的【当前颜色】已经是我们想要的【目标颜色】了，
	#    那就没必要再播放动画了，直接结束函数。
	if line_2d.default_color == target_color:
		return

	# 2. 检查：如果【已经有一个颜色过渡动画】正在朝向我们的目标颜色播放，
	#    那也没必要再创建一个新的了，同样直接结束函数。
	if is_instance_valid(line_color_tween) and line_color_tween.is_running():
		# 这个检查更复杂，我们先用一个更简单的方法
		pass # 我们先简化逻辑

	# --- 如果颜色确实需要改变，才执行后续的动画逻辑 ---
	
	# a) 先杀死任何可能还在运行的旧动画
	if is_instance_valid(line_color_tween):
		line_color_tween.kill()
	
	# b) 创建一个新的 Tween
	line_color_tween = create_tween()
	line_color_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	
	# c) 播放颜色过渡动画
	line_color_tween.tween_property(line_2d, "default_color", target_color, 0.003)



# --- 添加全新的、简化的滤镜控制函数 ---
func fade_slow_mo_filter(turn_on: bool):
	if not is_instance_valid(crt_effect) or not crt_effect.material: return

	var tween = create_tween().set_trans(Tween.TRANS_SINE)
	var final_mix_value = 1.0 if turn_on else 0.0
	
	# 我们只对 "slow_mo_mix" 这一个参数进行动画
	tween.tween_method(
		func(v): crt_effect.material.set_shader_parameter("slow_mo_mix", v),
		crt_effect.material.get_shader_parameter("slow_mo_mix"),
		final_mix_value,
		0.2
	)


func fade_radial_blur(turn_on: bool):
	if not is_instance_valid(radial_blur_effect) or not radial_blur_effect.material: 
		return
		
	if is_instance_valid(blur_tween):
		blur_tween.kill()
		
	blur_tween = create_tween()
	var current_blur = radial_blur_effect.material.get_shader_parameter("blur_strength")
	
	if turn_on:
		blur_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		
		# --- 【核心修复】真实时间换算 ---
		# 无论现在的慢动作是多少倍，我们都保证玩家在现实中按住 blur_charge_time (1.5秒) 就拉满
		var real_duration = blur_charge_time * Engine.time_scale
		
		blur_tween.tween_method(
			func(v): radial_blur_effect.material.set_shader_parameter("blur_strength", v),
			current_blur,
			max_blur_strength,
			real_duration 
		)
	else:
		blur_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
		
		# 恢复清晰同理：确保在现实的 0.2 秒内迅速收回
		var real_duration = 0.2 * Engine.time_scale
		
		blur_tween.tween_method(
			func(v): radial_blur_effect.material.set_shader_parameter("blur_strength", v),
			current_blur,
			0.0,
			real_duration 
		)


func _player_death_sequence():
	if is_dead: return
	is_dead = true
	
	# 1. 掐死可能还在跑的模糊动画
	if is_instance_valid(blur_tween):
		blur_tween.kill()
		
	# 2. 强行将径向模糊的强度重置为 0
	if is_instance_valid(radial_blur_effect) and radial_blur_effect.material:
		radial_blur_effect.material.set_shader_parameter("blur_strength", 0.0)
	
	# 【核心修正】调用新的瞬间停止函数
	if MusicManager:
		MusicManager.stop_immediately() 
	
	# --- 【新增】在执行任何暂停操作前，先广播“我死了”的信号 ---
	player_died.emit()
	
	# --- 【核心修改】在函数的最开始，立刻播放死亡音效 ---
	if is_instance_valid(death_audio_player):
		death_audio_player.play()
		
	lose_combo()

	Engine.time_scale = 1.0
	
	# 2. 立即暂停游戏
	get_tree().paused = true
	
	# 3. 创建一个可以在暂停时运行的 Tween
	var tween = create_tween()
	tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.set_trans(Tween.TRANS_SINE)

	# 4. 编排死亡动画序列
	tween.tween_property(death_effect, "modulate:a", 1.0, 0.3)
	tween.tween_interval(0.4)
	tween.tween_property(death_effect, "modulate:a", 0.0, 0.3)
	
	death_effect.show()

	# 5. 等待整个动画序列播放完毕
	await tween.finished
	
	# 6. 恢复与重启
	death_effect.hide()
	get_tree().paused = false
	get_tree().reload_current_scene()
