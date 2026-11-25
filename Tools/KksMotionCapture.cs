using System;
using System.Collections;
using System.IO;
using System.Linq;
using BepInEx;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

[BepInPlugin("local.myproject.kks-capture", "KKS offline motion capture", "1.0.0")]
public sealed class KksMotionCapture : BaseUnityPlugin
{
    private static readonly HumanBodyBones[] Bones = {
        HumanBodyBones.Hips, HumanBodyBones.Spine, HumanBodyBones.Chest,
        HumanBodyBones.Neck, HumanBodyBones.Head,
        HumanBodyBones.LeftUpperArm, HumanBodyBones.LeftLowerArm, HumanBodyBones.LeftHand,
        HumanBodyBones.RightUpperArm, HumanBodyBones.RightLowerArm, HumanBodyBones.RightHand,
        HumanBodyBones.LeftUpperLeg, HumanBodyBones.LeftLowerLeg, HumanBodyBones.LeftFoot,
        HumanBodyBones.RightUpperLeg, HumanBodyBones.RightLowerLeg, HumanBodyBones.RightFoot
    };
    private static readonly string[] KksBones = {
        "cf_j_hips", "cf_j_spine01", "cf_j_spine03", "cf_j_neck", "cf_j_head",
        "cf_j_arm00_L", "cf_j_forearm01_L", "cf_j_hand_L",
        "cf_j_arm00_R", "cf_j_forearm01_R", "cf_j_hand_R",
        "cf_j_thigh00_L", "cf_j_leg01_L", "cf_j_foot_L",
        "cf_j_thigh00_R", "cf_j_leg01_R", "cf_j_foot_R"
    };

    [Serializable]
    private sealed class Motion
    {
        public string source;
        public string clip;
        public float duration;
        public string[] bones;
        public Vector3[] samples;
    }

    private IEnumerator Start()
    {
        var plan = Environment.GetEnvironmentVariable("MYPROJECT_KKS_CAPTURE_PLAN");
        if (String.IsNullOrEmpty(plan))
            yield break;
        yield return null;
        try
        {
            var lines = File.ReadAllLines(plan);
            var bodyBundle = AssetBundle.LoadFromFile(lines[0]);
            var prefab = bodyBundle.LoadAsset<GameObject>("p_cf_body_bone");
            if (prefab == null)
                throw new InvalidOperationException("KKS body rig not found.");
            var body = Instantiate(prefab);
            body.SetActive(true);
            var animator = body.GetComponent<Animator>();
            if (animator == null)
                throw new InvalidOperationException("KKS prefab does not have an Animator.");
            animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
            animator.applyRootMotion = false;
            Logger.LogInfo("Using KKS rig " + animator.avatar.name + " (humanoid=" + animator.isHuman + ")");
            for (int i = 1; i < lines.Length; i += 4)
                Capture(animator, lines[i], lines[i + 1], lines[i + 2], lines[i + 3]);
            Application.Quit(0);
        }
        catch (Exception error)
        {
            Logger.LogError(error);
            Application.Quit(1);
        }
    }

    private void Capture(Animator animator, string path, string name, string source, string outputPath)
    {
        var bundle = AssetBundle.LoadFromFile(path);
        if (bundle == null)
            throw new InvalidOperationException("Cannot open animation bundle: " + path);
        var clip = bundle.LoadAllAssets<RuntimeAnimatorController>()
            .SelectMany(controller => controller.animationClips)
            .Concat(bundle.LoadAllAssets<AnimationClip>())
            .FirstOrDefault(item => item != null && item.name == name);
        if (clip == null)
            throw new InvalidOperationException("Missing clip: " + name);
        var transforms = animator.GetComponentsInChildren<Transform>(true);
        var joints = KksBones.Select(bone => transforms.First(x => x.name == bone)).ToArray();
        animator.Rebind();
        var graph = PlayableGraph.Create("Offline KKS Sampling");
        graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
        var playable = AnimationClipPlayable.Create(graph, clip);
        playable.SetApplyFootIK(false);
        var output = AnimationPlayableOutput.Create(graph, "Body", animator);
        output.SetSourcePlayable(playable);
        graph.Play();
        int steps = Math.Max(2, (int)Math.Ceiling(clip.length * 30));
        var motion = new Motion {
            source = source,
            clip = clip.name,
            duration = clip.length,
            bones = Bones.Select(bone => bone.ToString()).ToArray(),
            samples = new Vector3[(steps + 1) * joints.Length]
        };
        for (int frame = 0; frame <= steps; frame++)
        {
            playable.SetTime(clip.length * (double)frame / steps);
            graph.Evaluate(0);
            for (int joint = 0; joint < joints.Length; joint++)
                motion.samples[frame * joints.Length + joint] =
                    animator.transform.InverseTransformPoint(joints[joint].position);
        }
        graph.Destroy();
        if (!motion.samples.Skip(joints.Length).Select((point, i) =>
            (point - motion.samples[i % joints.Length]).sqrMagnitude).Any(delta => delta > 0.00001f))
            throw new InvalidOperationException("No KKS bone movement on the rig for " + motion.clip);
        File.WriteAllText(outputPath, JsonUtility.ToJson(motion));
        Logger.LogInfo("Captured " + motion.clip + " (" + steps + " samples)");
        bundle.Unload(true);
    }
}
