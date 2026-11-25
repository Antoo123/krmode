using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Xml;
using BepInEx;
using ExtensibleSaveFormat;
using KKAPI.Studio;
using Studio;
using UnityEngine;

[BepInPlugin("local.myproject.kks-studio-capture", "Godot Studio scene capture", "1.0.0")]
[BepInDependency("com.joan6694.illusionplugins.timeline", BepInDependency.DependencyFlags.SoftDependency)]
public sealed class KksStudioCapture : BaseUnityPlugin
{
    private const BindingFlags All = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;
    private FieldInfo timelineStart;
    private object timeline;
    private float nextTime = -1f;
    private Action beforeSkinning;

    [Serializable]
    private sealed class SceneManifest
    {
        public int version = 1;
        public string source;
        public string sha256;
        public float duration;
        public float timeScale;
        public int frames;
        public int timelineTracks;
        public int sourceTimelineTracks;
        public int timelineKeys;
        public int map;
        public int constraints;
        public string[] plugins;
        public string[] unboundTracks;
        public Vector3 cameraPosition;
        public Quaternion cameraRotation;
        public float cameraFov;
        public string colorGrade;
        public string playback;
        public string[] objects;
        public float[] cameraTrack;
        public Color cameraBackground;
    }

    [Serializable]
    private sealed class ActorManifest
    {
        public int key;
        public int sex;
        public bool ik;
        public bool fk;
        public int animeGroup;
        public int animeCategory;
        public int animeNumber;
        public float animeSpeed;
        public float animeNormalizedTime;
        public string[] clips;
        public string name;
        public string group;
        public int motionTracks;
        public string model;
        public string motion;
        public string visuals;
    }

    internal struct Pose
    {
        public Vector3 position;
        public Quaternion rotation;
        public Vector3 scale;

        public static Pose Read(Transform node, bool world)
        {
            return new Pose {
                position = world ? node.position : node.localPosition,
                rotation = world ? node.rotation : node.localRotation,
                scale = world ? node.lossyScale : node.localScale
            };
        }

        public bool Differs(Pose other)
        {
            var delta = Quaternion.Dot(rotation, other.rotation) >= 0f ? 1f : -1f;
            return (position - other.position).sqrMagnitude > 1e-12f ||
                (scale - other.scale).sqrMagnitude > 1e-12f ||
                new Vector4(rotation.x - delta * other.rotation.x, rotation.y - delta * other.rotation.y,
                    rotation.z - delta * other.rotation.z, rotation.w - delta * other.rotation.w).sqrMagnitude > 1e-12f;
        }

        public void Write(BinaryWriter writer)
        {
            writer.Write(position.x); writer.Write(position.y); writer.Write(-position.z);
            writer.Write(-rotation.x); writer.Write(-rotation.y); writer.Write(rotation.z); writer.Write(rotation.w);
            writer.Write(scale.x); writer.Write(scale.y); writer.Write(scale.z);
        }
    }

    private IEnumerator Start()
    {
        var plan = Environment.GetEnvironmentVariable("MYPROJECT_KKS_SCENE_PLAN");
        if (String.IsNullOrEmpty(plan))
            yield break;
        var capture = Capture(File.ReadAllLines(plan));
        while (true)
        {
            object instruction;
            try
            {
                if (!capture.MoveNext())
                    break;
                instruction = capture.Current;
            }
            catch (Exception error)
            {
                nextTime = -1f;
                Logger.LogError(error);
                Application.Quit(1);
                yield break;
            }
            yield return instruction;
        }
        File.WriteAllText(Path.Combine(Path.GetDirectoryName(plan), "scene-ok.txt"), "ok");
        Application.Quit(0);
    }

    // Timeline evaluates before the Animator and again after Studio's pose controllers.
    // Pin its clock in the early update stage, keeping the normal solver ordering intact.
    private void Awake()
    {
        var loop = UnityEngine.LowLevel.PlayerLoop.GetCurrentPlayerLoop();
        var systems = loop.subSystemList;
        for (int i = 0; i < systems.Length; i++)
        {
            var systemsInPhase = systems[i].subSystemList.ToList();
            if (systems[i].type == typeof(UnityEngine.PlayerLoop.Update))
                systemsInPhase.Insert(0, new UnityEngine.LowLevel.PlayerLoopSystem {
                    type = typeof(KksStudioCapture), updateDelegate = SetTimelineClock
                });
            if (systems[i].type == typeof(UnityEngine.PlayerLoop.PostLateUpdate))
            {
                int meshUpdate = systemsInPhase.FindIndex(system => system.type == typeof(UnityEngine.PlayerLoop.PostLateUpdate.UpdateAllSkinnedMeshes));
                if (meshUpdate >= 0)
                    systemsInPhase.Insert(meshUpdate, new UnityEngine.LowLevel.PlayerLoopSystem {
                        type = typeof(KksStudioVisualCapture), updateDelegate = CaptureBeforeSkinning
                    });
            }
            systems[i].subSystemList = systemsInPhase.ToArray();
        }
        UnityEngine.LowLevel.PlayerLoop.SetPlayerLoop(loop);
    }

    private void SetTimelineClock()
    {
        if (nextTime >= 0f)
            timelineStart.SetValue(timeline, Time.time - nextTime);
    }

    private void CaptureBeforeSkinning()
    {
        if (beforeSkinning != null)
            beforeSkinning();
    }

    private IEnumerator Capture(string[] plan)
    {
        var source = plan[0];
        var output = plan[1];
        var rate = Int32.Parse(plan[2], CultureInfo.InvariantCulture);
        var references = plan[3];
        int referenceStride = plan.Length > 5 ? Int32.Parse(plan[5], CultureInfo.InvariantCulture) : 1;
        var job = plan.Length > 6 ? plan[6] : null;
        bool workspaceOnly = plan.Length > 7 && plan[7] == "workspace";
        float timeout = Time.realtimeSinceStartup + 120;
        while (!StudioAPI.StudioLoaded && Time.realtimeSinceStartup < timeout)
            yield return null;
        if (!StudioAPI.StudioLoaded)
            throw new InvalidOperationException("Studio did not finish loading.");
        for (int i = 0; i < 10; i++)
            yield return null;
        var studio = Studio.Studio.Instance;
        Report(job, "reading");
        Logger.LogInfo("Loading " + source);
        if (!studio.LoadScene(source))
            throw new InvalidDataException("CharaStudio could not load the PNG scene.");
        for (int i = 0; i < 55; i++)
            yield return null;

        var timelineType = Type.GetType("Timeline.Timeline, Timeline", false);
        var timelineData = ExtendedSave.GetSceneExtendedDataById("timeline");
        var xml = new XmlDocument { XmlResolver = null };
        if (timelineData != null && timelineData.data.ContainsKey("sceneInfo"))
            xml.LoadXml((string)timelineData.data["sceneInfo"]);
        else
            xml.LoadXml("<timeline />");
        var sourceTracks = xml.SelectNodes("//interpolable");
        bool hasTimeline = sourceTracks.Count > 0;
        int boundTracks = 0;
        var unbound = new List<string>();
        float duration = 0f;
        if (hasTimeline)
        {
            if (timelineType == null)
                throw new InvalidDataException("This scene requires the Timeline plugin.");
            timeline = timelineType.GetField("_self", All).GetValue(null);
            timelineStart = timelineType.GetField("_startTime", All);
            var loaded = (IDictionary)timelineType.GetField("_interpolables", All).GetValue(timeline);
            boundTracks = loaded.Count;
            var trackModel = timelineType.Assembly.GetType("Timeline.InterpolableModel", true);
            var owner = trackModel.GetField("owner", All);
            var id = trackModel.GetField("id", All);
            var loadedCounts = loaded.Values.Cast<object>().GroupBy(track => owner.GetValue(track) + ":" + id.GetValue(track))
                .ToDictionary(group => group.Key, group => group.Count());
            foreach (XmlNode track in sourceTracks)
            {
                string key = track.Attributes["owner"].Value + ":" + track.Attributes["id"].Value;
                int count;
                if (loadedCounts.TryGetValue(key, out count) && count > 0)
                    loadedCounts[key] = count - 1;
                else
                    unbound.Add(key);
            }
            if (boundTracks == 0)
                throw new InvalidDataException("Studio could not bind Timeline tracks: " + String.Join(", ", unbound.ToArray()));
            duration = (float)timelineType.GetField("_duration", All).GetValue(timeline);
            if (duration <= 0)
                throw new InvalidDataException("Timeline duration must be positive.");
        }
        float timeScale = Time.timeScale;
        var characters = studio.dicObjectCtrl.OrderBy(entry => entry.Key)
            .Select(entry => entry.Value).OfType<OCIChar>()
            .Where(actor => actor.treeNodeObject.visible && actor.charInfo.gameObject.activeInHierarchy).ToArray();
        var exporter = FindObjectOfType<KksCardCapture>();
        if (exporter == null)
            throw new InvalidOperationException("KCS capture plugin was not loaded.");
        var animatorsByActor = characters.Select(actor => actor.charInfo.GetComponentsInChildren<Animator>(true)
            .Where(animator => animator.runtimeAnimatorController != null && animator.isActiveAndEnabled).ToArray()).ToArray();
        if (!hasTimeline)
        {
            for (int i = 0; i < characters.Length; i++)
                if (characters[i].oiCharInfo.animeSpeed > 0f)
                    foreach (var animator in animatorsByActor[i])
                        foreach (var clip in animator.GetCurrentAnimatorClipInfo(0))
                            if (clip.weight > 0f)
                                duration = Mathf.Max(duration, clip.clip.length / characters[i].oiCharInfo.animeSpeed);
            foreach (var item in studio.dicObjectCtrl.Values.OfType<OCIItem>())
                if (item.isAnime && Mathf.Abs(item.animeSpeed) > 0.0001f && item.objectItem != null)
                    foreach (var animator in item.objectItem.GetComponentsInChildren<Animator>(true))
                        if (animator.runtimeAnimatorController != null && animator.isActiveAndEnabled)
                            foreach (var clip in animator.GetCurrentAnimatorClipInfo(0))
                                if (clip.weight > 0f)
                                    duration = Mathf.Max(duration, clip.clip.length / Mathf.Abs(item.animeSpeed));
        }
        if (duration > 300 || timeScale <= 0)
            throw new InvalidDataException("Scene duration or time scale is outside the supported range.");
        int frames = Mathf.CeilToInt(duration * rate / timeScale) + 1;
        var manifest = new SceneManifest {
            source = Path.GetFileName(source), sha256 = plan[4],
            duration = duration / timeScale, timeScale = timeScale, frames = frames,
            timelineTracks = boundTracks, sourceTimelineTracks = sourceTracks.Count,
            timelineKeys = xml.SelectNodes("//keyframe").Count, unboundTracks = unbound.ToArray(),
            map = studio.sceneInfo.map,
            playback = hasTimeline ? "timeline" : (frames > 1 ? "clip" : "pose"),
            objects = studio.dicObjectCtrl.OrderBy(entry => entry.Key).Select(entry =>
                entry.Key + ":" + entry.Value.GetType().Name + ":" + entry.Value.treeNodeObject.textName).ToArray()
        };
        var sourceCamera = Camera.main;
        if (sourceCamera != null)
        {
            var p = sourceCamera.transform.position;
            var q = sourceCamera.transform.rotation;
            manifest.cameraPosition = new Vector3(p.x, p.y, -p.z);
            manifest.cameraRotation = new Quaternion(-q.x, -q.y, q.z, q.w);
            manifest.cameraFov = sourceCamera.fieldOfView;
            manifest.cameraBackground = sourceCamera.backgroundColor;
        }
        var sceneData = (IDictionary)typeof(ExtendedSave).GetField("internalSceneDictionary", All).GetValue(null);
        manifest.plugins = sceneData.Keys.Cast<string>().OrderBy(key => key).ToArray();
        var constraints = ExtendedSave.GetSceneExtendedDataById("nodesConstraints");
        if (constraints != null && constraints.data.ContainsKey("constraints"))
        {
            var document = new XmlDocument { XmlResolver = null };
            document.LoadXml((string)constraints.data["constraints"]);
            manifest.constraints = document.DocumentElement.ChildNodes.Count;
        }

        var workspace = new KksWorkspaceCapture(studio, output, exporter, frames);
        var bones = workspaceOnly ? new Transform[0][] :
            characters.Select(actor => actor.charInfo.transform.GetComponentsInChildren<Transform>(true)).ToArray();
        var samples = new Pose[characters.Length][][];
        var actors = new ActorManifest[characters.Length];
        for (int i = 0; i < characters.Length; i++)
        {
            var actor = characters[i];
            var saved = actor.oiCharInfo;
            var animators = animatorsByActor[i];
            actors[i] = new ActorManifest {
                key = saved.dicKey, sex = actor.charInfo.sex, ik = saved.enableIK, fk = saved.enableFK,
                name = actor.treeNodeObject.textName, group = GroupName(actor.treeNodeObject.parent),
                animeGroup = saved.animeInfo.group, animeCategory = saved.animeInfo.category, animeNumber = saved.animeInfo.no,
                animeSpeed = saved.animeSpeed, animeNormalizedTime = saved.animeNormalizedTime,
                clips = animators.SelectMany(animator => animator.GetCurrentAnimatorClipInfo(0)).Select(info => info.clip.name).Distinct().ToArray(),
                model = "actor-" + i + ".kcs", motion = "actor-" + i + ".kst", visuals = "actor-" + i + ".ksv"
            };
            foreach (var animator in animators)
            {
                animator.cullingMode = AnimatorCullingMode.AlwaysAnimate;
                animator.Play(animator.GetCurrentAnimatorStateInfo(0).fullPathHash, 0, saved.animeNormalizedTime);
                animator.Update(0f);
            }
            if (!workspaceOnly)
                samples[i] = new Pose[frames][];
        }
        if (!workspaceOnly && WriteColorGrade(sourceCamera, Path.Combine(output, "color-grade.ksl")))
            manifest.colorGrade = "color-grade.ksl";
        Logger.LogInfo(ToJson(manifest, actors));
        Time.captureFramerate = rate;
        PropertyInfo playback = null;
        if (hasTimeline)
        {
            timelineType.GetProperty("isPlaying", All).SetValue(null, true, null);
            playback = timelineType.GetProperty("playbackTime", All);
        }
        var endOfFrame = new WaitForEndOfFrame();
        var visual = new KksStudioVisualCapture[characters.Length];
        var actorMeshes = new List<Renderer>[characters.Length];
        var cameraFrames = sourceCamera != null ? new float[frames * 8] : null;
        int visualFrames = frames > 1 ? Mathf.Min(frames, Mathf.CeilToInt(manifest.duration * 12f) + 1) : 1;
        int visualIndex = 0;
        // Keep the skeletal sampling rate independent of the mesh cache budget.
        if (frames <= 121)
            visualFrames = frames;
        if (characters.Length >= 4 && frames > 1)
            visualFrames = Mathf.Min(visualFrames, Mathf.CeilToInt(manifest.duration * 15f) + 1);
        var materialsReport = new StringWriter(CultureInfo.InvariantCulture);
        int capturedFrame = -1;
        int sampleIndex = 0;
        Exception sampleError = null;
        beforeSkinning = () =>
        {
            try
            {
                for (int i = 0; i < bones.Length; i++)
                {
                    if (visual[i] == null)
                    {
                        actorMeshes[i] = workspace.ActorMeshes(actors[i].key, bones[i][0]);
                        visual[i] = new KksStudioVisualCapture(bones[i][0], visualFrames, actorMeshes[i]);
                    }
                    samples[i][sampleIndex] = ReadPose(bones[i]);
                    if (visualIndex < visualFrames &&
                        sampleIndex == Mathf.RoundToInt(visualIndex * (frames - 1f) / Mathf.Max(1, visualFrames - 1)))
                        visual[i].Sample(visualIndex);
                }
                capturedFrame = Time.frameCount;
            }
            catch (Exception error)
            {
                sampleError = error;
                beforeSkinning = null;
            }
        };
        if (!String.IsNullOrEmpty(references))
            foreach (var canvas in FindObjectsOfType<Canvas>())
                canvas.enabled = false;
        for (int frame = 0; frame < frames; frame++)
        {
            if (frame == 0 || frame == frames - 1 || frame % Math.Max(rate / 2, 1) == 0)
                Report(job, "capturing:" + frame + ":" + frames);
            sampleIndex = frame;
            if (hasTimeline)
                nextTime = Mathf.Clamp(duration * frame / (frames - 1), 0.0001f, duration - 0.0001f);
            yield return null;
            yield return endOfFrame;
            if (hasTimeline && Mathf.Abs((float)playback.GetValue(null, null) - nextTime) > 0.001f)
                throw new InvalidOperationException("Timeline did not evaluate the requested sample at frame " + frame);
            if (sampleError != null || capturedFrame != Time.frameCount)
                throw new InvalidOperationException("Could not sample the renderer update at frame " + frame, sampleError);
            workspace.Sample(frame);
            if (visualIndex < visualFrames &&
                frame == Mathf.RoundToInt(visualIndex * (frames - 1f) / Mathf.Max(1, visualFrames - 1)))
                visualIndex++;
            if (cameraFrames != null)
            {
                var p = sourceCamera.transform.position;
                var q = sourceCamera.transform.rotation;
                int offset = frame * 8;
                cameraFrames[offset] = p.x;
                cameraFrames[offset + 1] = p.y;
                cameraFrames[offset + 2] = -p.z;
                cameraFrames[offset + 3] = -q.x;
                cameraFrames[offset + 4] = -q.y;
                cameraFrames[offset + 5] = q.z;
                cameraFrames[offset + 6] = q.w;
                cameraFrames[offset + 7] = sourceCamera.fieldOfView;
            }
            bool writeReference = !String.IsNullOrEmpty(references) && (frame == frames - 1 || frame % referenceStride == 0);
            if (writeReference)
            {
                var image = ScreenCapture.CaptureScreenshotAsTexture();
                File.WriteAllBytes(Path.Combine(references, "studio-" + frame.ToString("D3") + ".png"), image.EncodeToPNG());
                Destroy(image);
                workspace.Describe(materialsReport, frame, workspaceOnly);
            }
            for (int i = 0; i < bones.Length; i++)
            {
                var transforms = bones[i];
                if (frame == 0)
                    exporter.Export(transforms[0], Path.Combine(output, actors[i].model), nativeSkin: true,
                        workspaceRenderers: actorMeshes[i]);
                if (writeReference)
                    KksStudioVisualCapture.Describe(transforms[0], materialsReport, i, frame);
            }
        }
        beforeSkinning = null;
        nextTime = -1f;
        if (hasTimeline)
            timelineType.GetProperty("isPlaying", All).SetValue(null, false, null);
        Report(job, "encoding");
        workspace.Save(manifest.duration);
        for (int i = 0; i < bones.Length; i++)
        {
            actors[i].motionTracks = WriteMotion(Path.Combine(output, actors[i].motion), samples[i]);
            visual[i].Save(Path.Combine(output, actors[i].visuals));
            visual[i].Dispose();
            visual[i] = null;
            samples[i] = null;
            yield return null;
        }
        if (!String.IsNullOrEmpty(references))
        {
            File.WriteAllText(Path.Combine(references, "timeline.xml"), xml.OuterXml);
            File.WriteAllText(Path.Combine(references, "materials.tsv"), materialsReport.ToString());
        }
        if (cameraFrames != null && Enumerable.Range(8, cameraFrames.Length - 8)
            .Any(i => Mathf.Abs(cameraFrames[i] - cameraFrames[i % 8]) > 0.00001f))
            manifest.cameraTrack = cameraFrames;
        else if (cameraFrames != null)
        {
            manifest.cameraPosition = new Vector3(cameraFrames[0], cameraFrames[1], cameraFrames[2]);
            manifest.cameraRotation = new Quaternion(cameraFrames[3], cameraFrames[4], cameraFrames[5], cameraFrames[6]);
            manifest.cameraFov = cameraFrames[7];
        }
        File.WriteAllText(Path.Combine(output, "scene.json"), ToJson(manifest, actors));
    }

    private static string GroupName(TreeNodeObject node)
    {
        var names = new List<string>();
        for (; node != null; node = node.parent)
            names.Add(node.textName);
        names.Reverse();
        return String.Join(" / ", names.ToArray());
    }

    private static void Report(string job, string phase)
    {
        if (!String.IsNullOrEmpty(job))
            try { File.WriteAllText(Path.Combine(job, "phase.txt"), phase); }
            catch (IOException) { } // The viewer can be reading the previous progress update.
    }

    private static string ToJson(SceneManifest manifest, ActorManifest[] actors)
    {
        var header = JsonUtility.ToJson(manifest, true);
        return header.Substring(0, header.LastIndexOf('}')).TrimEnd() +
            ",\n  \"actors\": [\n" + String.Join(",\n", actors.Select(actor => JsonUtility.ToJson(actor)).ToArray()) + "\n  ]\n}";
    }

    private static Pose[] ReadPose(Transform[] transforms)
    {
        var poses = new Pose[transforms.Length];
        for (int joint = 0; joint < transforms.Length; joint++)
            poses[joint] = Pose.Read(transforms[joint], joint == 0);
        return poses;
    }

    private static bool WriteColorGrade(Camera camera, string filename)
    {
        var grade = camera == null ? null : camera.GetComponent<AmplifyColorEffect>();
        if (grade == null || !grade.isActiveAndEnabled || (grade.LutTexture == null && grade.LutBlendTexture == null))
            return false;
        const int edge = 32;
        const int width = edge * edge;
        var identity = new Texture2D(width, edge, TextureFormat.RGBA32, false, true);
        var pixels = new Color32[width * edge];
        for (int green = 0; green < edge; green++)
            for (int blue = 0; blue < edge; blue++)
                for (int red = 0; red < edge; red++)
                    pixels[green * width + blue * edge + red] = new Color(red / 31f, green / 31f, blue / 31f, 1f);
        identity.SetPixels32(pixels);
        identity.Apply(false);
        var source = RenderTexture.GetTemporary(width, edge, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
        var target = RenderTexture.GetTemporary(width, edge, 0, RenderTextureFormat.ARGB32, RenderTextureReadWrite.Linear);
        var previous = RenderTexture.active;
        try
        {
            Graphics.Blit(identity, source);
            typeof(AmplifyColorBase).GetMethod("OnRenderImage", All).Invoke(grade, new object[] { source, target });
            RenderTexture.active = target;
            identity.ReadPixels(new Rect(0, 0, width, edge), 0, 0);
            File.WriteAllBytes(filename, identity.EncodeToPNG());
        }
        finally
        {
            RenderTexture.active = previous;
            RenderTexture.ReleaseTemporary(source);
            RenderTexture.ReleaseTemporary(target);
            Destroy(identity);
        }
        return true;
    }

    private static int WriteMotion(string path, Pose[][] frames)
    {
        var joints = Enumerable.Range(0, frames[0].Length)
            .Where(joint => joint == 0 || frames.Skip(1).Any(frame => frame[joint].Differs(frames[0][joint]))).ToArray();
        using (var writer = new BinaryWriter(File.Create(path)))
        {
            writer.Write(0x3154534b); // KST1, indexed against the KCS from the same capture.
            writer.Write(frames.Length);
            writer.Write(frames[0].Length);
            writer.Write(joints.Length);
            foreach (var joint in joints)
            {
                writer.Write(joint);
                foreach (var frame in frames)
                    frame[joint].Write(writer);
            }
        }
        return joints.Length;
    }

}
