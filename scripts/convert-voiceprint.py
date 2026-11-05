# Converts the WeSpeaker ResNet34-LM speaker model (VoxCeleb, CC BY 4.0) into
# Resources/models/SpeakerEmbedding.mlpackage, the voiceprint model behind 实验功能 › 分出对方的每个人.
# Developer-only, run once; the app needs no Python. Needs Python 3.11 with
#   torch==2.5.1 coremltools==8.3.0 onnx onnx2torch "numpy<2" onnxruntime
# and the ONNX file from WeSpeaker (docs/pretrained.md, voxceleb_resnet34_LM.onnx,
# sha256 7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068).
# usage: python3 scripts/convert-voiceprint.py voxceleb_resnet34_LM.onnx Resources/models/SpeakerEmbedding.mlpackage
import sys, numpy as np, torch, onnx, onnxruntime as ort, coremltools as ct
from onnx import numpy_helper as nh
from onnx2torch import convert
src, out = sys.argv[1], sys.argv[2]
model = onnx.load(src)
inits = {i.name: nh.to_array(i) for i in model.graph.initializer}
# Core ML can't convert the pooling's dynamic-shape ops (Shape → ReduceProd), so convert the
# ResNet trunk up to its last ReLU and redo statistics pooling below.
import tempfile, os
trunk_path = os.path.join(tempfile.mkdtemp(), "trunk.onnx")
onnx.utils.extract_model(src, trunk_path, ["feats"], ["343"])
trunk = convert(onnx.load(trunk_path)).eval()

class Embed(torch.nn.Module):
    """ResNet trunk + statistics pooling rewritten without the dynamic-shape ops Core ML lacks."""
    def __init__(self):
        super().__init__()
        self.trunk = trunk
        self.fc = torch.nn.Linear(5120, 256)
        self.fc.weight.data = torch.from_numpy(inits["model.seg_1.weight"])
        self.fc.bias.data = torch.from_numpy(inits["model.seg_1.bias"])
        self.register_buffer("mean_vec", torch.from_numpy(inits["mean_vec"]))
    def forward(self, feats):
        x = self.trunk(feats)                       # [1, C, F, T']
        mu = x.mean(-1)
        n = torch.ones_like(x).sum(-1)              # T' without reading the shape
        var = ((x - mu.unsqueeze(-1)) ** 2).mean(-1) * n / (n - 1)
        sd = torch.sqrt(var + 1e-8)
        z = torch.cat([mu.flatten(1), sd.flatten(1)], 1)
        return self.fc(z) - self.mean_vec

m = Embed().eval()
sess = ort.InferenceSession(src)
x = torch.randn(1, 300, 80)
with torch.no_grad():
    print("torch vs onnx max diff", np.abs(sess.run(None, {"feats": x.numpy()})[0] - m(x).numpy()).max())
tr = torch.jit.trace(m, x)
ml = ct.convert(tr, inputs=[ct.TensorType(name="feats", shape=(1, ct.RangeDim(50, 6000, default=300), 80))],
                outputs=[ct.TensorType(name="embs")], minimum_deployment_target=ct.target.macOS14,
                compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
ml.short_description = "WeSpeaker ResNet34-LM speaker embedding (VoxCeleb, CC BY 4.0)"
ml.save(out)
for T in (80, 150, 300, 801, 2000):
    x = np.random.randn(1, T, 80).astype(np.float32)
    a = sess.run(None, {"feats": x})[0][0]
    b = ml.predict({"feats": x})["embs"][0]
    print(T, "cos onnx vs coreml", round(float(a @ b / np.linalg.norm(a) / np.linalg.norm(b)), 5))
