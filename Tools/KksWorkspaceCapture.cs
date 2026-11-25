using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Security.Cryptography;
using Studio;
using UnityEngine;
using Pose = KksStudioCapture.Pose;

internal sealed class KksWorkspaceCapture
{
    private const BindingFlags Members = BindingFlags.Public | BindingFlags.NonPublic |
        BindingFlags.Instance | BindingFlags.Static;

    [Serializable]
    private sealed class Entry
    {
        public int key, parentKey = -1, anchorKey = -1, anchorBoneIndex = -1, anchorAxes;
        public string name, type, anchorBone, model, track, issue;
        public bool visible;
        public string[] bodyNames;
        public int[] bodyOffsets, bodyChanges;
        public int[] anchorStates;
        public string[] legacyRendererNames;
        public int[] legacyRendererOwners;
    }

    [Serializable]
    private sealed class Manifest
    {
        public int version = 1, frames;
        public float duration;
        public bool embeddedItems;
        public string[] warnings;
    }

    [Serializable]
    private sealed class Link
    {
        public int sourceKey, targetKey, axes;
        public string sourceTransform, targetTransform;
        public bool enabled;
    }

    private sealed class PoseTrack
    {
        public readonly List<int> Keys = new List<int>();
        public readonly List<Pose> Values = new List<Pose>();
        private Pose previous;

        public void Sample(int frame, Pose pose)
        {
            if (frame > 0 && !pose.Differs(previous))
                return;
            if (frame > 0 && Keys[Keys.Count - 1] < frame - 1)
            {
                Keys.Add(frame - 1);
                Values.Add(previous);
            }
            Keys.Add(frame);
            Values.Add(pose);
            previous = pose;
        }
    }

    private sealed class Visibility
    {
        public readonly List<int> Changes = new List<int>();
        private bool previous;

        public void Sample(int frame, bool value)
        {
            if (frame == 0 || value != previous)
                Changes.Add((frame << 1) | (value ? 1 : 0));
            previous = value;
        }
    }

    private sealed class Tint
    {
        public Renderer renderer;
        public int slot;
        public int channel;
        public readonly List<int> Keys = new List<int>();
        public readonly List<Color> Colors = new List<Color>();
        private Vector4 previous;

        public void Sample(int frame, Vector4 color)
        {
            if (Keys.Count > 0 && (color - previous).sqrMagnitude < 1e-9f)
                return;
            if (Keys.Count > 0 && Keys[Keys.Count - 1] < frame - 1)
            {
                Keys.Add(frame - 1);
                Colors.Add(previous);
            }
            Keys.Add(frame);
            Colors.Add(color);
            previous = color;
        }
    }

    private sealed class Item
    {
        public Entry entry;
        public Transform root;
        public Transform[] bones;
        public PoseTrack[] poses;
        public Renderer[] renderers;
        public Visibility[] visibility;
        public Tint[][] tints;
        public bool everVisible;
        public object constraint;
        public FieldInfo constraintEnabled;
        public readonly Visibility anchorState = new Visibility();
    }

    private sealed class Body
    {
        public Entry entry;
        public Renderer[] meshes;
        public Visibility[] visibility;
    }

    private readonly string output;
    private readonly KksCardCapture exporter;
    private readonly int frames;
    private readonly List<Item> items = new List<Item>();
    private readonly Dictionary<int, Entry> entries = new Dictionary<int, Entry>();
    private readonly Dictionary<Transform, int> owners = new Dictionary<Transform, int>();
    private readonly Dictionary<int, Transform> actorRoots = new Dictionary<int, Transform>();
    private readonly List<string> warnings = new List<string>();
    private readonly List<Body> bodies = new List<Body>();
    private readonly List<Link> links = new List<Link>();
    private readonly List<Material> materials = new List<Material>();
    private readonly MaterialPropertyBlock materialBlock = new MaterialPropertyBlock();
    private bool embeddedItems;

    public KksWorkspaceCapture(Studio.Studio studio, string output, KksCardCapture exporter, int frames)
    {
        this.output = output;
        this.exporter = exporter;
        this.frames = frames;
        var objects = studio.dicObjectCtrl.OrderBy(pair => pair.Key).ToArray();
        var nodes = objects.ToDictionary(pair => pair.Value.treeNodeObject, pair => pair.Key);
        foreach (var pair in objects)
        {
            var control = pair.Value;
            var entry = new Entry {
                key = pair.Key, name = control.treeNodeObject.textName, type = control.GetType().Name,
                visible = control.treeNodeObject.visible
            };
            int parent;
            if (control.treeNodeObject.parent != null && nodes.TryGetValue(control.treeNodeObject.parent, out parent))
                entry.parentKey = parent;
            entries.Add(pair.Key, entry);
            if (control.guideObject != null && control.guideObject.transformTarget != null)
                owners[control.guideObject.transformTarget] = pair.Key;
            var actor = control as OCIChar;
            if (actor != null)
            {
                var root = actor.charInfo.transform;
                owners[root] = pair.Key;
                actorRoots.Add(pair.Key, root);
            }
            var item = control as OCIItem;
            if (item != null && item.objectItem != null)
                owners[item.objectItem.transform] = pair.Key;
        }
        foreach (var pair in objects)
        {
            var actor = pair.Value as OCIChar;
            if (actor != null)
            {
                var details = new HashSet<string>(StringComparer.OrdinalIgnoreCase) {
                    "o_mnpa", "o_mnpb", "o_dankon", "o_dan_f", "o_gomu", "cm_o_dan00", "cm_o_dan_f"
                };
                var meshes = actor.charInfo.GetComponentsInChildren<Renderer>(true)
                    .Where(mesh => details.Contains(mesh.name) && Owner(mesh.transform) == pair.Key).ToArray();
                if (meshes.Length > 0)
                    bodies.Add(new Body { entry = entries[pair.Key], meshes = meshes,
                        visibility = meshes.Select(mesh => new Visibility()).ToArray() });
            }
            var item = pair.Value as OCIItem;
            var folder = pair.Value as OCIFolder;
            Transform root = item != null && item.objectItem != null ? item.objectItem.transform :
                folder != null && folder.objectItem != null ? folder.objectItem.transform : null;
            if (root == null)
                continue;
            var entry = entries[pair.Key];
            var renderers = item == null ? new Renderer[0] : root.GetComponentsInChildren<Renderer>(true)
                .Where(mesh => KksCardCapture.IsWorkspaceMesh(mesh) && Owner(mesh.transform) == pair.Key).ToArray();
            var bones = renderers.Length > 0 ? root.GetComponentsInChildren<Transform>(true) : new[] { root };
            if (bones.Length > 4096 || renderers.Length > 256)
            {
                entry.issue = "Mesh exceeds KCS limits.";
                renderers = new Renderer[0];
                bones = new[] { root };
            }
            if (item != null && renderers.Length == 0 && entry.issue == null)
                entry.issue = root.GetComponentsInChildren<ParticleSystem>(true).Length > 0 ?
                    "Particle system is not baked." : "Controller or no supported mesh.";
            var tints = renderers.Select(mesh => mesh.sharedMaterials.SelectMany((material, slot) =>
                Enumerable.Range(0, KksWorkspaceMaterial.Parameters.Length).Select(channel =>
                    new Tint { renderer = mesh, slot = slot, channel = channel })).ToArray()).ToArray();
            items.Add(new Item {
                entry = entry, root = root, bones = bones, renderers = renderers, tints = tints,
                poses = bones.Select(bone => new PoseTrack()).ToArray(),
                visibility = renderers.Select(mesh => new Visibility()).ToArray()
            });
            var parentTransform = root.parent;
            while (parentTransform != null && Owner(parentTransform) == pair.Key)
                parentTransform = parentTransform.parent;
            int physicalParent = Owner(parentTransform);
            if (physicalParent >= 0)
                SetAnchor(entry, physicalParent, parentTransform, 7);
            if (renderers.Length > 0 && actorRoots.Values.Any(actorRoot => root.IsChildOf(actorRoot)))
                embeddedItems = true;
        }
    }

    public List<Renderer> ActorMeshes(int key, Transform root)
    {
        return KksCardCapture.ExportRenderers(root).Where(renderer => Owner(renderer.transform) == key).ToList();
    }

    private int Owner(Transform transform)
    {
        for (; transform != null; transform = transform.parent)
        {
            int key;
            if (owners.TryGetValue(transform, out key))
                return key;
        }
        return -1;
    }

    private void SetAnchor(Entry entry, int key, Transform transform, int axes)
    {
        entry.anchorKey = key;
        entry.anchorAxes = axes;
        entry.anchorBone = "";
        Transform root;
        if (actorRoots.TryGetValue(key, out root))
            for (var bone = transform; bone != null && bone != root; bone = bone.parent)
                if (bone.name.StartsWith("cf_j_", StringComparison.OrdinalIgnoreCase))
                {
                    entry.anchorBone = bone.name;
                    entry.anchorBoneIndex = Array.IndexOf(root.GetComponentsInChildren<Transform>(true), bone);
                    break;
                }
    }

    private void ReadConstraints()
    {
        try
        {
            var type = Type.GetType("NodesConstraints.NodesConstraints, NodesConstraints", false);
            var plugin = type == null ? null : UnityEngine.Object.FindObjectOfType(type);
            if (plugin == null)
                return;
            var records = (IEnumerable)type.GetField("_constraints", Members).GetValue(plugin);
            var conflicts = new HashSet<int>();
            var assigned = new HashSet<int>();
            foreach (var rule in records)
            {
                var fields = rule.GetType();
                var parent = (Transform)fields.GetField("parentTransform", Members).GetValue(rule);
                var child = (Transform)fields.GetField("childTransform", Members).GetValue(rule);
                int axes = ((bool)fields.GetField("position", Members).GetValue(rule) ? 1 : 0) |
                    ((bool)fields.GetField("rotation", Members).GetValue(rule) ? 2 : 0) |
                    ((bool)fields.GetField("scale", Members).GetValue(rule) ? 4 : 0);
                int target = Owner(child), source = Owner(parent);
                links.Add(new Link { sourceKey = source, targetKey = target, axes = axes,
                    sourceTransform = parent != null ? parent.name : "",
                    targetTransform = child != null ? child.name : "",
                    enabled = (bool)fields.GetField("enabled", Members).GetValue(rule) });
                var item = items.Find(candidate => candidate.entry.key == target);
                if (source < 0 || source == target || item == null || axes == 0)
                    continue;
                // Internal IK channels have already been baked. Only an object root can be rebound.
                if (child != item.root && !item.root.IsChildOf(child))
                    continue;
                if (!assigned.Add(target))
                {
                    conflicts.Add(target);
                    continue;
                }
                SetAnchor(item.entry, source, parent, axes);
                item.constraint = rule;
                item.constraintEnabled = fields.GetField("enabled", Members);
            }
            foreach (int key in conflicts)
            {
                entries[key].anchorKey = -1;
                warnings.Add("Several NodesConstraints drive item #" + key + ". Its evaluated motion is baked.");
            }
        }
        catch (Exception error)
        {
            warnings.Add("NodesConstraints rebind metadata could not be read: " + error.Message);
        }
    }

    public void Sample(int frame)
    {
        if (frame == 0)
        {
            ReadConstraints();
            if (embeddedItems)
                foreach (var actor in actorRoots)
                {
                    var raw = actor.Value.GetComponentsInChildren<Renderer>(false);
                    if (!raw.Any(KksCardCapture.IsWorkspaceMesh))
                        continue;
                    try
                    {
                        var meshes = KksCardCapture.ExportRenderers(actor.Value);
                        var keys = meshes.Select(mesh => Owner(mesh.transform)).ToArray();
                        if (keys.Any(key => key >= 0 && key != actor.Key))
                        {
                            entries[actor.Key].legacyRendererNames = meshes.Select(mesh => mesh.name).ToArray();
                            entries[actor.Key].legacyRendererOwners = keys;
                        }
                    }
                    catch (InvalidDataException) { }
                }
        }
        foreach (var item in items)
        {
            if (item.constraintEnabled != null)
                item.anchorState.Sample(frame, (bool)item.constraintEnabled.GetValue(item.constraint));
            // The root is stored in world coordinates; internal bones keep their local transforms.
            for (int i = 0; i < item.bones.Length; i++)
                item.poses[i].Sample(frame, Pose.Read(item.bones[i], i == 0));
            for (int i = 0; i < item.renderers.Length; i++)
            {
                var mesh = item.renderers[i];
                bool visible = IsVisible(mesh);
                item.visibility[i].Sample(frame, visible);
                item.everVisible |= visible;
                if (mesh == null || !visible)
                    continue;
                mesh.GetSharedMaterials(materials);
                foreach (var tint in item.tints[i])
                {
                    if (tint.slot >= materials.Count || materials[tint.slot] == null)
                        continue;
                    if (tint.channel == 0)
                        KksWorkspaceMaterial.ReadBlock(mesh, tint.slot, materialBlock);
                    tint.Sample(frame, KksWorkspaceMaterial.Sample(materials[tint.slot], materialBlock, tint.channel));
                }
            }
        }
        foreach (var body in bodies)
            for (int i = 0; i < body.meshes.Length; i++)
                body.visibility[i].Sample(frame, IsVisible(body.meshes[i]));
    }

    private static bool IsVisible(Renderer mesh)
    {
        return mesh != null && mesh.enabled && mesh.gameObject.activeInHierarchy && !mesh.forceRenderingOff;
    }

    public void Describe(TextWriter report, int frame, bool includeActors)
    {
        foreach (var item in items)
            foreach (var mesh in item.renderers)
                if (frame == 0 || IsVisible(mesh))
                    KksStudioVisualCapture.DescribeRenderer(mesh, report, item.entry.key, frame);
        if (includeActors)
            foreach (var actor in actorRoots)
                KksStudioVisualCapture.Describe(actor.Value, report, actor.Key, frame);
    }

    public void Save(float duration)
    {
        var models = new Dictionary<string, string>();
        using (var hash = SHA256.Create())
        foreach (var item in items)
        {
            var entry = item.entry;
            if (item.anchorState.Changes.Count > 0)
                entry.anchorStates = item.anchorState.Changes.ToArray();
            try
            {
                if (item.everVisible && item.renderers.Length > 0)
                {
                    var model = "prop-" + entry.key + ".kcs";
                    var path = Path.Combine(output, model);
                    exporter.Export(item.root, path, nativeSkin: true,
                        workspaceRenderers: item.renderers.ToList(), workspaceMaterial: KksWorkspaceMaterial.Write);
                    string fingerprint;
                    using (var stream = File.OpenRead(path))
                        fingerprint = Convert.ToBase64String(hash.ComputeHash(stream));
                    string previous;
                    if (models.TryGetValue(fingerprint, out previous))
                    {
                        File.Delete(path);
                        model = previous;
                    }
                    else
                        models.Add(fingerprint, model);
                    entry.model = model;
                }
                var track = "prop-" + entry.key + ".kwp";
                WriteTrack(Path.Combine(output, track), item);
                entry.track = track;
            }
            catch (Exception error)
            {
                entry.model = null;
                entry.issue = error.Message;
                warnings.Add("Item #" + entry.key + " could not be exported: " + error.Message);
            }
        }
        foreach (var body in bodies)
        {
            body.entry.bodyNames = body.meshes.Select(mesh => mesh.name).ToArray();
            var offsets = new List<int> { 0 };
            var changes = new List<int>();
            foreach (var track in body.visibility)
            {
                changes.AddRange(track.Changes);
                offsets.Add(changes.Count);
            }
            body.entry.bodyOffsets = offsets.ToArray();
            body.entry.bodyChanges = changes.ToArray();
        }
        var header = JsonUtility.ToJson(new Manifest {
            frames = frames, duration = duration, embeddedItems = embeddedItems,
            warnings = warnings.ToArray()
        }, true);
        var rows = entries.Values.OrderBy(entry => entry.key).Select(entry => JsonUtility.ToJson(entry)).ToArray();
        var bindings = links.Select(link => JsonUtility.ToJson(link)).ToArray();
        File.WriteAllText(Path.Combine(output, "workspace.json"), header.Substring(0, header.LastIndexOf('}')).TrimEnd() +
            ",\n  \"entries\": [\n" + String.Join(",\n", rows) + "\n  ],\n  \"links\": [\n" +
            String.Join(",\n", bindings) + "\n  ]\n}");
    }

    private static void WriteTrack(string path, Item item)
    {
        int bones = item.entry.model == null ? 1 : item.poses.Length;
        var tintTracks = item.entry.model == null ? new Tint[0] :
            item.tints.SelectMany(group => group).Where(tint => tint.Keys.Count > 1).ToArray();
        using (var writer = new BinaryWriter(File.Create(path)))
        {
            writer.Write(0x3250574b); // KWP2
            writer.Write(bones);
            int[] joints = Enumerable.Range(0, bones).Where(i => i == 0 || item.poses[i].Keys.Count > 1).ToArray();
            writer.Write(joints.Length);
            foreach (int joint in joints)
            {
                var track = item.poses[joint];
                writer.Write(joint);
                writer.Write(track.Keys.Count);
                for (int i = 0; i < track.Keys.Count; i++)
                {
                    writer.Write(track.Keys[i]);
                    track.Values[i].Write(writer);
                }
            }
            int renderers = item.entry.model == null ? 0 : item.visibility.Length;
            writer.Write(renderers);
            for (int i = 0; i < renderers; i++)
            {
                var changes = item.visibility[i].Changes;
                writer.Write(changes.Count);
                foreach (int change in changes)
                    writer.Write(change);
            }
            writer.Write(tintTracks.Length);
            foreach (var tint in tintTracks)
            {
                writer.Write(Array.IndexOf(item.renderers, tint.renderer));
                writer.Write(tint.slot);
                writer.Write(tint.channel);
                writer.Write(tint.Keys.Count);
                for (int i = 0; i < tint.Keys.Count; i++)
                {
                    var color = tint.Colors[i];
                    writer.Write(tint.Keys[i]);
                    writer.Write(color.r); writer.Write(color.g); writer.Write(color.b); writer.Write(color.a);
                }
            }
        }
    }
}
