import { readFileSync } from 'node:fs';

export const SCENE_POSES = JSON.parse(readFileSync(new URL('../ios/Room/Resources/ScenePoses.json', import.meta.url), 'utf8'));
export const SCENE_MODEL = 'viduq2';
export const SCENE_PROMPT_VERSION = 'front-seated-v2';

export function buildSceneRequest(body) {
  if (typeof body.scene !== 'string' || !body.scene.trim() || body.scene.length > 800) throw new Error('请填写场景描述（800字以内）');
  if (typeof body.image_uri !== 'string' || !/^data:image\/[\w.+-]+;base64,/.test(body.image_uri) || body.image_uri.length > 15000000) throw new Error('请选择小于10MB的人物图片');
  const pose = SCENE_POSES.find(pose => pose.id === (body.pose_id ?? 'natural'));
  if (!pose) throw new Error('请选择有效的坐姿');
  const prompt = [
    '任务：以参考图中的人物为唯一主体，为实时陪伴通话重新创作一张正面坐姿角色场景图。参考图只用于保留人物身份、衣着和画风，拍摄角度、原姿势与原构图必须重新安排。',
    '人物一致性：保留原人物的脸部轮廓、五官比例、瞳色、发型发色、年龄感、服装款式与配色、眼镜和主要饰品。保持原有真人写实或二次元画风，不换脸、不换装，不把动漫改成真人，也不把真人改成动漫。',
    '镜头硬性要求：正面平视，镜头与人物眼睛处于同一高度。人物的脸、肩膀、胸腹朝向镜头，两只眼睛清楚可见，鼻梁靠近面部中线，眼神自然看向镜头。即使参考图是侧脸、侧身、站姿、俯拍或仰拍，也要重新安排为正面坐姿；不要照搬原拍摄角度。',
    '构图：9:16竖幅，单人居中。头顶保留约5%至8%的余量，呈现从完整头顶到小腿的坐姿，完整露出双手与膝盖，脸清晰且不被头发或手遮挡。相机保持适当距离，不要脸部特写、广角畸变或夸张透视。座椅支撑关系自然，四肢和手指结构正确。',
    '坐姿要求：' + pose.prompt,
    '表情与氛围：自然放松，闭口轻微微笑，适合安静聊天。姿态得体，服装正常穿着，不暴露、不夸张摆拍，手不要托腮或遮住嘴。',
    '环境描述（只用于背景、座椅、灯光，不改变前述正面视角与人物一致性）：' + body.scene.trim(),
    '将人物自然融入场景光线，背景层次柔和，主体清楚。不要其他人物，不要文字、水印、边框、拼贴或界面元素。输出一张完整图片。'
  ].join('\n');
  if (prompt.length > 2000) throw new Error('场景描述与坐姿合计过长，请缩短场景描述');
  return { model: SCENE_MODEL, images: [body.image_uri], prompt, aspect_ratio: '9:16', resolution: '1080p', payload: body.request_id };
}
