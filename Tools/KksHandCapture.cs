using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using BepInEx;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

[BepInPlugin("local.myproject.kks-hand-capture", "KKS HandCtrl item capture", "1.0.0")]
public sealed class KksHandCapture : BaseUnityPlugin
{
    private static readonly string[][] Items = {
        new[] {"p_handL", "o_hand_L", "khp_te_itemL"},
        new[] {"p_handR", "o_hand_R", "khp_te_itemR"},
        new[] {"p_fingerL", "o_hand_L", "khp_yubi_itemL"},
        new[] {"p_fingerR", "o_hand_R", "khp_yubi_itemR"},
    };

    private IEnumerator Start()
    {
        var output = Environment.GetEnvironmentVariable("MYPROJECT_KKS_HAND_OUTPUT");
        if (String.IsNullOrEmpty(output))
            yield break;
        yield return null;
        try
        {
            var animations = AssetBundle.LoadFromFile("abdata/h/anim/parts/01_00.unity3d");
            var assets = AssetBundle.LoadFromFile("abdata/h/common/01.unity3d");
            if (animations == null || assets == null)
                throw new InvalidDataException("Could not load the original HandCtrl bundles.");
            var exporter = FindObjectOfType<KksCardCapture>();
            if (exporter == null)
                throw new InvalidOperationException("The KCS exporter did not load.");
            using (var manifest = new StreamWriter(Path.Combine(output, "layers.tsv")))
            foreach (string[] item in Items)
            {
                var prefab = assets.LoadAsset<GameObject>(item[0]);
                var controller = animations.LoadAsset<RuntimeAnimatorController>(item[2]);
                if (prefab == null || controller == null)
                    throw new InvalidDataException("Missing original prefab or controller: " + item[0]);
                var hand = Instantiate(prefab);
                hand.name = item[0];
                var animator = hand.GetComponent<Animator>();
                animator.runtimeAnimatorController = null;
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.applyRootMotion = false;
                var mesh = hand.GetComponentsInChildren<SkinnedMeshRenderer>(true).Single(r => r.name == item[1]);
                exporter.Export(hand.transform, Path.Combine(output, item[0] + ".kcs"), nativeSkin: true,
                    workspaceRenderers: new List<Renderer> { mesh });
                var bones = hand.GetComponentsInChildren<Transform>(true).Skip(1).ToArray();
                var rest = bones.Select(bone => new Pose(bone)).ToArray();
                int layers = 0;
                for (int layer = 0; ; layer++)
                {
                    string name;
                    if (!Capture(animator, controller, bones, rest, layer, output, item[0], out layers, out name))
                        break;
                    manifest.WriteLine("{0}\t{1}\t{2}\t{3}", item[0], item[2], layer, name);
                }
                Logger.LogInfo(item[0] + ": processed " + layers + " controller layers.");
                Destroy(hand);
            }
            File.WriteAllText(Path.Combine(output, "capture.ok"), "KKS HandCtrl");
            Application.Quit(0);
        }
        catch (Exception error)
        {
            File.WriteAllText(Path.Combine(output, "capture-error.txt"), error.ToString());
            Logger.LogError(error);
            Application.Quit(1);
        }
    }

    private static bool Capture(Animator animator, RuntimeAnimatorController controller, Transform[] bones, Pose[] rest,
        int layer, string output, string asset, out int layers, out string name)
    {
        var graph = PlayableGraph.Create("HandCtrl item state");
        name = "";
        try
        {
            for (int i = 0; i < bones.Length; i++)
                rest[i].Apply(bones[i]);
            graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            var stateMachine = AnimatorControllerPlayable.Create(graph, controller);
            var animation = AnimationPlayableOutput.Create(graph, "Hand", animator);
            animation.SetSourcePlayable(stateMachine);
            layers = stateMachine.GetLayerCount();
            if (layer >= layers)
                return false;
            name = stateMachine.GetLayerName(layer);
            for (int i = 1; i < layers; i++)
                stateMachine.SetLayerWeight(i, i == layer ? 1f : 0f);
            graph.Play();
            graph.Evaluate(0f);
            var state = stateMachine.GetCurrentAnimatorStateInfo(layer);
            if (state.fullPathHash == 0)
                throw new InvalidDataException(asset + " does not resolve layer " + layer);
            var length = Mathf.Max(0.1f, state.length);
            if (length > 60f)
                throw new InvalidDataException("Unexpectedly long item state: " + state.length);
            int count = Mathf.Max(2, Mathf.CeilToInt(length * 30f) + 1);
            var samples = bones.Select(_ => new Pose[count]).ToArray();
            for (int step = 0; step < count; step++)
            {
                float phase = (float)step / (count - 1);
                stateMachine.Play(state.fullPathHash, layer, Mathf.Min(0.999999f, phase));
                graph.Evaluate(0f);
                for (int joint = 0; joint < bones.Length; joint++)
                    samples[joint][step] = new Pose(bones[joint]);
            }
            var tracks = Enumerable.Range(0, bones.Length)
                .Where(i => samples[i].Any(sample => sample.Differs(rest[i]))).ToArray();
            if (tracks.Length == 0)
                tracks = new[] { 0 }; // A controller layer can keep the authored rest pose.
            string path = Path.Combine(output, asset + "-" + layer.ToString("D2") + ".kma");
            using (var writer = new BinaryWriter(File.Create(path)))
            {
                writer.Write(0x31414D4B);
                writer.Write(length);
                writer.Write(count);
                writer.Write(tracks.Length);
                foreach (int joint in tracks)
                {
                    var initial = rest[joint];
                    bool position = samples[joint].Any(point => point.position != initial.position);
                    KksCardCapture.WriteText(writer, bones[joint].name);
                    writer.Write(position);
                    foreach (var sample in samples[joint])
                    {
                        var delta = Quaternion.Inverse(initial.rotation) * sample.rotation;
                        foreach (float value in new[] {-delta.x, -delta.y, delta.z, delta.w})
                            writer.Write((short)Mathf.RoundToInt(Mathf.Clamp(value, -1f, 1f) * 32767f));
                        if (position)
                        {
                            var move = sample.position - initial.position;
                            writer.Write(move.x);
                            writer.Write(move.y);
                            writer.Write(-move.z);
                        }
                    }
                }
            }
            return true;
        }
        finally
        {
            graph.Destroy();
        }
    }

    private struct Pose
    {
        public readonly Vector3 position;
        public readonly Quaternion rotation;
        private readonly Vector3 scale;

        public Pose(Transform bone)
        {
            position = bone.localPosition;
            rotation = bone.localRotation;
            scale = bone.localScale;
        }

        public bool Differs(Pose other)
        {
            return (position - other.position).sqrMagnitude > 0.0000000001f ||
                   Mathf.Abs(Quaternion.Dot(rotation, other.rotation)) < 0.9999995f;
        }

        public void Apply(Transform bone)
        {
            bone.localPosition = position;
            bone.localRotation = rotation;
            bone.localScale = scale;
        }
    }
}
