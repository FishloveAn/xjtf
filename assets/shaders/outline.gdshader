shader_type spatial;
render_mode cull_front, unshaded;

// 特感描边轮廓（美术方向 §5.3 / 替换清单附录 C：提升剪影辨识，类无主之地简版）
// 用法：作为特感 mesh 材质的 next_pass，顶点沿法线外扩 + 渲染背面，形成深色描边。

uniform vec4 outline_color : source_color = vec4(0.02, 0.02, 0.03, 1.0);
uniform float outline_width = 0.03;

void vertex() {
	VERTEX += NORMAL * outline_width;
}

void fragment() {
	ALBEDO = outline_color.rgb;
	ALPHA = outline_color.a;
}
