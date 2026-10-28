-- #160 接缝 A 取证第 1 步（客户端）：读取当前镜头位置与焦点，供服务端探针把模型摆到镜头前。
-- 试玩就绪后：editor-cli exec -p client --file <本文件绝对路径>，再 log grep SEAMA_CAM 取回。
-- 输出一行：SEAMA_CAM <相机x> <相机y> <相机z> <焦点x> <焦点y> <焦点z>
local cam = game:GetService('CameraService').MainCamera
if not cam then print('SEAMA_CAM ABORT 没有主相机') return end
local p, f = cam.Position, cam.Focus
print(string.format('SEAMA_CAM %.3f %.3f %.3f %.3f %.3f %.3f', p.x, p.y, p.z, f.x, f.y, f.z))
