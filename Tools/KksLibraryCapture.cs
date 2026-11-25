using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using BepInEx;
using UnityEngine;
using UnityEngine.Animations;
using UnityEngine.Playables;

[BepInPlugin("local.myproject.kks-library-capture", "Godot animation library capture", "1.0.0")]
public sealed class KksLibraryCapture : BaseUnityPlugin
{
    private sealed class Track
    {
        public Transform Bone;
        public Vector3 Position;
        public Quaternion Rotation;
        public Vector3[] Positions;
        public Quaternion[] Rotations;
        public bool HasPositions;
        public bool HasRotations;
    }

    private IEnumerator Start()
    {
        string plan = Environment.GetEnvironmentVariable("MYPROJECT_KKS_LIBRARY_PLAN");
        if (String.IsNullOrEmpty(plan))
            yield break;
        yield return null;
        try { ConvertPlan(plan); }
        catch (Exception error) { Logger.LogError(error); Application.Quit(1); yield break; }
        Application.Quit(0);
    }

    private void ConvertPlan(string path)
    {
        var plan = File.ReadAllLines(path);
        var body = AssetBundle.LoadFromFile(plan[0]);
        var actor = Instantiate(body.LoadAsset<GameObject>("p_cf_body_bone"));
        actor.SetActive(true);
        var animator = actor.GetComponent<Animator>();
        animator.applyRootMotion = false;
        animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
        var bones = animator.GetComponentsInChildren<Transform>(true)
            .Where(item => item.name.StartsWith("cf_j_", StringComparison.OrdinalIgnoreCase))
            .GroupBy(item => item.name, StringComparer.OrdinalIgnoreCase).Select(group => group.First()).ToArray();
        var positions = bones.Select(bone => bone.localPosition).ToArray();
        var rotations = bones.Select(bone => bone.localRotation).ToArray();
        var requests = plan.Skip(2).Select(line => line.Split('\t'));
        using (var report = new StreamWriter(plan[1], true))
        {
            foreach (var group in requests.GroupBy(fields => fields[0]))
            {
                AssetBundle bundle = null;
                try
                {
                    bundle = AssetBundle.LoadFromFile(group.Key);
                    if (bundle == null) throw new IOException("Cannot open the bundle");
                    var clips = group.Any(fields => fields.Length == 3)
                        ? bundle.LoadAllAssets<RuntimeAnimatorController>()
                            .SelectMany(controller => controller.animationClips)
                            .Concat(bundle.LoadAllAssets<AnimationClip>())
                            .Where(clip => clip != null).Distinct().ToLookup(clip => clip.name)
                        : null;
                    foreach (var clipRows in group.GroupBy(fields => fields.Length == 4 ? fields[3] : fields[1]))
                    {
                        var rows = clipRows.ToArray();
                        var choices = rows[0].Length == 4
                            ? new[] { bundle.LoadAsset<AnimationClip>(clipRows.Key) }.Where(clip => clip != null).ToArray()
                            : clips[clipRows.Key].ToArray();
                        if (choices.Length != 1 || rows.Length != 1)
                        {
                            foreach (var row in rows)
                                Report(report, row[2], choices.Length == 0 ? "missing" : "ambiguous");
                            continue;
                        }
                        string output = rows[0][2];
                        try
                        {
                            if (!File.Exists(output))
                                Capture(animator, choices[0], bones, positions, rotations, output);
                            Report(report, output, "converted");
                        }
                        catch (Exception error) { Report(report, output, error.Message); }
                    }
                }
                catch (Exception error)
                {
                    foreach (var row in group)
                        Report(report, row[2], error.Message);
                }
                finally { if (bundle != null) bundle.Unload(true); }
                report.Flush();
            }
        }
    }

    private static void Report(StreamWriter report, string output, string status)
    {
        report.WriteLine(Path.GetFileNameWithoutExtension(output) + "\t" + status.Replace('\n', ' ').Replace('\r', ' '));
    }

    private static void Capture(Animator animator, AnimationClip clip, Transform[] bones,
        Vector3[] positions, Quaternion[] rotations, string output)
    {
        int steps = Mathf.Clamp(Mathf.CeilToInt(clip.length * 15), 1, 1800);
        var tracks = bones.Select((bone, i) => new Track {
            Bone = bone, Position = positions[i], Rotation = rotations[i],
            Positions = new Vector3[steps + 1], Rotations = new Quaternion[steps + 1]
        }).ToArray();
        animator.Rebind();
        foreach (var track in tracks)
        {
            track.Bone.localPosition = track.Position;
            track.Bone.localRotation = track.Rotation;
        }
        var graph = PlayableGraph.Create("Godot KKS library export");
        try
        {
            graph.SetTimeUpdateMode(DirectorUpdateMode.Manual);
            var playable = AnimationClipPlayable.Create(graph, clip);
            playable.SetApplyFootIK(false);
            AnimationPlayableOutput.Create(graph, "Body", animator).SetSourcePlayable(playable);
            graph.Play();
            for (int i = 0; i <= steps; i++)
            {
                playable.SetTime(clip.length * (double)i / steps);
                graph.Evaluate(0);
                foreach (var track in tracks)
                {
                    Quaternion delta = Quaternion.Inverse(track.Rotation) * track.Bone.localRotation;
                    track.Rotations[i] = delta;
                    track.HasRotations |= Mathf.Abs(delta.w) < 0.999999f;
                    Vector3 position = track.Bone.localPosition - track.Position;
                    track.Positions[i] = position;
                    track.HasPositions |= position.sqrMagnitude > 0.000004f;
                }
            }
        }
        finally { graph.Destroy(); }
        var active = tracks.Where(track => track.HasRotations || track.HasPositions).ToArray();
        if (active.Length == 0)
            throw new InvalidDataException("no compatible body tracks");
        string partial = output + ".partial";
        using (var writer = new BinaryWriter(File.Create(partial)))
        {
            writer.Write(0x31414D4B); // KMA1
            writer.Write(clip.length);
            writer.Write(steps + 1);
            writer.Write(active.Length);
            foreach (var track in active)
            {
                byte[] name = Encoding.UTF8.GetBytes(track.Bone.name);
                writer.Write(name.Length);
                writer.Write(name);
                writer.Write(track.HasPositions);
                for (int i = 0; i <= steps; i++)
                {
                    var q = track.Rotations[i];
                    writer.Write(Pack(-q.x)); writer.Write(Pack(-q.y)); writer.Write(Pack(q.z)); writer.Write(Pack(q.w));
                    if (track.HasPositions)
                    {
                        var p = track.Positions[i];
                        writer.Write(p.x); writer.Write(p.y); writer.Write(-p.z);
                    }
                }
            }
        }
        File.Move(partial, output);
    }

    private static short Pack(float component)
    {
        return (short)Mathf.RoundToInt(Mathf.Clamp(component, -1f, 1f) * 32767);
    }
}
