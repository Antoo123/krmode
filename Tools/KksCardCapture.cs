using System;
using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using BepInEx;
using KKAPI.Studio;
using Studio;
using UnityEngine;

[BepInPlugin("local.myproject.kks-card-capture", "Godot card and outfit capture", "1.0.0")]
public sealed class KksCardCapture : BaseUnityPlugin
{
    private const BindingFlags InstanceProperties = BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public;

    private IEnumerator Start()
    {
        string plan = Environment.GetEnvironmentVariable("MYPROJECT_KKS_CARD_PLAN");
        if (String.IsNullOrEmpty(plan))
            yield break;
        float started = Time.realtimeSinceStartup;
        while (!StudioAPI.StudioLoaded && Time.realtimeSinceStartup - started < 120)
            yield return null;
        if (!StudioAPI.StudioLoaded)
        {
            Logger.LogError("Studio did not finish loading.");
            Application.Quit(1);
            yield break;
        }
        string[] lines = File.ReadAllLines(plan);
        bool batch = lines.Length > 5;
        for (int i = 0; i < lines.Length; i += 5)
        {
            var studio = Studio.Studio.Instance;
            var before = new HashSet<int>(studio.dicObjectCtrl.Keys);
            OCIChar loaded;
            try
            {
                var card = new ChaFileControl();
                byte sex = Byte.Parse(lines[i + 1]);
                if (!card.LoadCharaFile(lines[i], sex, false, false))
                    throw new InvalidDataException("Studio could not parse the card.");
                if (sex == Byte.MaxValue)
                    sex = card.parameter.sex;
                if (sex == 0)
                    studio.AddMale(lines[i]);
                else
                    studio.AddFemale(lines[i]);
            }
            catch (Exception error)
            {
                if (!batch) { Fail(error); yield break; }
                Logger.LogError(lines[i] + ": " + error);
                studio.InitScene(false);
                continue;
            }
            for (int tick = 0; tick < 12; tick++)
                yield return null;
            try
            {
                loaded = studio.dicObjectCtrl.Where(item => !before.Contains(item.Key))
                    .Select(item => item.Value).OfType<OCIChar>().Single();
                var actor = loaded;
                int coordinate = Int32.Parse(lines[i + 2]);
                if (coordinate >= 0)
                    actor.SetCoordinateInfo((ChaFileDefine.CoordinateType)coordinate, true);
                if (!String.IsNullOrEmpty(lines[i + 4]))
                {
                    var outfit = new ChaFileCoordinate();
                    if (!outfit.LoadFile(lines[i + 4]))
                        throw new InvalidDataException("Studio could not parse the outfit card.");
                    actor.LoadClothesFile(lines[i + 4]);
                    Logger.LogInfo("Loaded outfit card " + Path.GetFileName(lines[i + 4]));
                }
                actor.charInfo.animBody.enabled = false;
                Logger.LogInfo("Loaded card and outfit " + Path.GetFileName(lines[i]));
            }
            catch (Exception error)
            {
                if (!batch) { Fail(error); yield break; }
                Logger.LogError(lines[i] + ": " + error);
                studio.InitScene(false);
                continue;
            }
            for (int tick = 0; tick < 8; tick++)
                yield return null;
            if (String.IsNullOrEmpty(Environment.GetEnvironmentVariable("MYPROJECT_KKS_WARDROBE")))
            {
                var character = loaded.charInfo;
                var selector = character.GetComponents<MonoBehaviour>().FirstOrDefault(component =>
                    component != null && component.GetType().FullName == "KK_Plugins.UncensorSelector+UncensorSelectorController");
                bool changed;
                try { changed = ApplyUncensorProfile(selector); }
                catch (Exception error) { Fail(error); yield break; }
                if (changed)
                    for (int tick = 0; tick < 4; tick++)
                        yield return null;
                if (selector != null)
                {
                    var display = selector.GetType().GetProperty("DisplayPenis", InstanceProperties);
                    if (display != null)
                        loaded.SetVisibleSon((bool)display.GetValue(selector, null));
                    Logger.LogInfo("Uncensor Selector applied to the captured card.");
                    yield return null;
                }
            }
            string comparison = Environment.GetEnvironmentVariable("MYPROJECT_KKS_COMPARE");
            if (!String.IsNullOrEmpty(comparison))
            {
                string top = Environment.GetEnvironmentVariable("MYPROJECT_KKS_COMPARE_TOP");
                bool found = String.IsNullOrEmpty(top);
                foreach (string candidate in found ? new string[0] : top.Split(','))
                {
                    try
                    {
                        loaded.charInfo.ChangeClothesNoAsync(0, Int32.Parse(candidate), 0, 0, 0, true, true);
                        loaded.charInfo.SetClothesState(0, 0, true);
                    }
                    catch (Exception error) { Logger.LogWarning(error.Message); continue; }
                    yield return null;
                    yield return null;
                    var piece = loaded.charInfo.objClothes[0];
                    if (piece != null && piece.GetComponentsInChildren<Renderer>(false).Any(IsRenderable))
                    {
                        File.WriteAllText(comparison + "-item.txt", candidate);
                        found = true;
                        break;
                    }
                }
                try
                {
                    if (!found)
                        throw new InvalidDataException("The comparison garment has no visible mesh.");
                    SaveComparison(loaded.charInfo, comparison);
                    Export(loaded.charInfo.transform, comparison + "-actor.kcs");
                }
                catch (Exception error) { Fail(error); yield break; }
            }
            string wardrobe = Environment.GetEnvironmentVariable("MYPROJECT_KKS_WARDROBE");
            if (!String.IsNullOrEmpty(wardrobe))
                yield return StartCoroutine(ExportWardrobe(loaded.charInfo, wardrobe, loaded.charInfo.sex));
            try
            {
                var actor = studio.dicObjectCtrl.Where(item => !before.Contains(item.Key))
                    .Select(item => item.Value).OfType<OCIChar>().Single();
                Export(actor.charInfo.transform, lines[i + 3]);
                Logger.LogInfo("Wrote " + lines[i + 3]);
                if (i + 5 < lines.Length)
                    studio.InitScene(false);
            }
            catch (Exception error)
            {
                if (!batch) { Fail(error); yield break; }
                Logger.LogError(lines[i] + ": " + error);
                studio.InitScene(false);
            }
        }
        Finish("ok", 0);
    }

    private bool ApplyUncensorProfile(MonoBehaviour selector)
    {
        bool changed = false;
        foreach (var part in new[] { "Body", "Penis", "Balls" })
        {
            string guid = Environment.GetEnvironmentVariable("MYPROJECT_KKS_" + part.ToUpperInvariant() + "_GUID");
            if (String.IsNullOrEmpty(guid))
                continue;
            if (selector == null)
                throw new InvalidOperationException("An explicit anatomy profile requires the installed Uncensor Selector plugin.");
            var type = selector.GetType();
            var dictionary = type.DeclaringType.GetField(part + "Dictionary", BindingFlags.Public | BindingFlags.Static);
            var entries = dictionary == null ? null : dictionary.GetValue(null) as IDictionary;
            if (entries == null || !entries.Contains(guid))
                throw new InvalidDataException("Anatomy GUID unavailable for " + part + ": " + guid);
            type.GetProperty(part + "GUID", InstanceProperties).SetValue(selector, guid, null);
            if (part != "Body")
                type.GetProperty("Display" + part, InstanceProperties).SetValue(selector, true, null);
            Logger.LogInfo("Selected anatomy " + part + ": " + guid);
            changed = true;
        }
        if (changed)
            selector.GetType().GetMethod("UpdateUncensor").Invoke(selector, null);
        return changed;
    }

    private void Fail(Exception error)
    {
        Logger.LogError(error);
        Finish(error.Message, 1);
    }

    private static void Finish(string message, int exitCode)
    {
        string result = Environment.GetEnvironmentVariable("MYPROJECT_KKS_CARD_RESULT");
        if (!String.IsNullOrEmpty(result))
            File.WriteAllText(result, message);
        Application.Quit(exitCode);
    }

    private IEnumerator ExportWardrobe(ChaControl character, string output, byte sex)
    {
        Directory.CreateDirectory(output);
        int limit;
        Int32.TryParse(Environment.GetEnvironmentVariable("MYPROJECT_KKS_WARDROBE_LIMIT"), out limit);
        int onlyCategory;
        Int32.TryParse(Environment.GetEnvironmentVariable("MYPROJECT_KKS_WARDROBE_CATEGORY"), out onlyCategory);
        string listing = Path.Combine(output, "catalog-" + sex + ".tsv");
        var entries = new List<Tuple<int, int, string, int>>();
        for (int category = 101; category <= 112; category++)
        {
            var information = character.lstCtrl.GetCategoryInfo((ChaListDefine.CategoryNo)category);
            if (information == null)
                continue;
            foreach (var item in information.OrderBy(x => x.Key))
            {
                var name = item.Value.GetInfo(ChaListDefine.KeyType.Name).Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');
                entries.Add(Tuple.Create(category, item.Key, name, item.Value.GetInfoInt(ChaListDefine.KeyType.Sex)));
            }
        }
        File.WriteAllLines(listing, entries.Select(item => item.Item1 + "\t" + item.Item2 + "\t" + item.Item3 + "\t" + item.Item4));
        int done = 0;
        using (var report = new StreamWriter(Path.Combine(output, "status-" + sex + ".tsv"), true))
        {
            foreach (var group in entries.GroupBy(item => item.Item1))
            {
                if (onlyCategory != 0 && group.Key != onlyCategory)
                    continue;
                if (group.Key >= 105)
                    character.SetClothesStateAll(2);
                foreach (var row in limit > 0 ? group.Take(limit) : group)
                {
                    if (done % 40 == 0 && new DriveInfo(Path.GetPathRoot(output)).AvailableFreeSpace < 6L * 1024 * 1024 * 1024)
                        throw new IOException("Wardrobe export stopped at the free-space reserve.");
                    int category = row.Item1, id = row.Item2;
                    bool hair = category < 105;
                    int slot = category - (hair ? 101 : 105);
                    string prefix = Path.Combine(output, sex + "-" + category + "-" + id);
                    if (File.Exists(prefix + ".kcs"))
                        continue;
                    try
                    {
                        if (hair)
                            character.ChangeHairNoAsync(slot, id, true);
                        else
                        {
                            character.ChangeClothesNoAsync(slot, id, 0, 0, 0, true, true);
                            character.SetClothesState(slot, 0, false);
                        }
                    }
                    catch (Exception error) { report.WriteLine(Path.GetFileName(prefix) + "\t" + error.GetType().Name); report.Flush(); continue; }
                    yield return null;
                    yield return null;
                    try
                    {
                        var parts = hair ? character.objHair : character.objClothes;
                        int actualSlot = !hair && slot == 7 && parts.Length > 8 && parts[8] != null ? 8 : slot;
                        var piece = parts[actualSlot];
                        if (piece == null)
                            throw new InvalidDataException("missing rendered item");
                        Func<Renderer, bool> belongs = renderer => renderer.transform.IsChildOf(piece.transform) ||
                            (!hair && IsBodyRenderer(renderer));
                        var before = piece.GetComponentsInChildren<Renderer>(false).Where(IsRenderable).ToArray();
                        if (before.Length == 0)
                            throw new InvalidDataException("no visible item meshes");
                        Export(character.transform, prefix + ".kcs", belongs);
                        if (!hair)
                        {
                            character.SetClothesState(slot, 1, false);
                            var after = piece.GetComponentsInChildren<Renderer>(false).Where(IsRenderable).ToArray();
                            if (after.Length > 0 && !before.SequenceEqual(after))
                                Export(character.transform, prefix + "-half.kcs", belongs);
                            character.SetClothesState(slot, 0, false);
                        }
                        report.WriteLine(Path.GetFileName(prefix) + "\tready");
                        done++;
                    }
                    catch (Exception error) { report.WriteLine(Path.GetFileName(prefix) + "\t" + error.Message.Replace('\t', ' ').Replace('\n', ' ')); }
                    report.Flush();
                    if (done % 40 == 0)
                    {
                        Resources.UnloadUnusedAssets();
                        yield return null;
                    }
                }
            }
        }
    }

    private static void SaveComparison(ChaControl character, string prefix)
    {
        var actor = character.transform;
        var view = new GameObject("Comparison camera");
        var capture = view.AddComponent<Camera>();
        capture.enabled = false;
        capture.clearFlags = CameraClearFlags.SolidColor;
        capture.backgroundColor = new Color32(68, 73, 84, 255);
        capture.fieldOfView = 33;
        var target = RenderTexture.GetTemporary(640, 720, 24, RenderTextureFormat.ARGB32);
        var image = new Texture2D(640, 720, TextureFormat.RGBA32, false);
        var active = RenderTexture.active;
        try
        {
            capture.targetTexture = target;
            foreach (var shot in new[] {
                Tuple.Create("body", 0.95f, 3.3f),
                Tuple.Create("face", 1.37f, 1.0f),
                Tuple.Create("legs", 0.34f, 1.25f)
            })
                WriteComparisonShot(actor, capture, image, prefix + "-" + shot.Item1 + ".png", shot.Item2, shot.Item3);
            WriteComparisonMaterials(actor, prefix + "-materials.txt");
            var clothes = character.objClothes.Where(piece => piece != null)
                .SelectMany(piece => piece.GetComponentsInChildren<Renderer>(false)).Where(r => r.enabled).Distinct().ToArray();
            var masks = actor.GetComponentsInChildren<Renderer>(false).Where(IsBodyRenderer)
                .SelectMany(renderer => renderer.sharedMaterials).Where(m => m != null && m.HasProperty("_AlphaMask"))
                .Distinct().ToDictionary(m => m, m => m.GetTexture("_AlphaMask"));
            try
            {
                foreach (var renderer in clothes)
                    renderer.enabled = false;
                foreach (var material in masks.Keys)
                    material.SetTexture("_AlphaMask", Texture2D.whiteTexture);
                WriteComparisonShot(actor, capture, image, prefix + "-rear.png", 0.94f, -1.55f);
            }
            finally
            {
                foreach (var renderer in clothes)
                    renderer.enabled = true;
                foreach (var pair in masks)
                    pair.Key.SetTexture("_AlphaMask", pair.Value);
            }
        }
        finally
        {
            RenderTexture.active = active;
            capture.targetTexture = null;
            RenderTexture.ReleaseTemporary(target);
            Destroy(image);
            Destroy(view);
        }
    }

    private static void WriteComparisonShot(Transform actor, Camera camera, Texture2D image, string path, float height, float distance)
    {
        camera.transform.position = actor.TransformPoint(new Vector3(0, height, distance));
        camera.transform.LookAt(actor.TransformPoint(Vector3.up * height));
        camera.Render();
        RenderTexture.active = camera.targetTexture;
        image.ReadPixels(new Rect(0, 0, image.width, image.height), 0, 0);
        File.WriteAllBytes(path, image.EncodeToPNG());
    }

    private static void WriteComparisonMaterials(Transform actor, string path)
    {
        var report = new List<string>();
        foreach (var renderer in actor.GetComponentsInChildren<Renderer>(false)
            .Where(r => IsBodyRenderer(r) || r.name.IndexOf("face", StringComparison.OrdinalIgnoreCase) >= 0
                || r.name.IndexOf("hair", StringComparison.OrdinalIgnoreCase) >= 0))
        {
            var mesh = SourceMesh(renderer);
            if (mesh != null)
                report.Add(renderer.name + " | local scale " + renderer.transform.lossyScale.ToString("F4")
                    + " | UV counts " + mesh.uv.Length + " / " + mesh.uv2.Length + " / " + mesh.uv3.Length + " / " + mesh.uv4.Length);
            foreach (var material in renderer.sharedMaterials)
            {
                if (material == null || material.shader == null)
                    continue;
                report.Add(renderer.name + " | " + material.name + " | " + material.shader.name);
                for (int i = 0; i < material.shader.GetPropertyCount(); i++)
                {
                    var name = material.shader.GetPropertyName(i);
                    switch (material.shader.GetPropertyType(i))
                    {
                        case UnityEngine.Rendering.ShaderPropertyType.Texture:
                            var map = material.GetTexture(name);
                            report.Add(name + " = " + (map == null ? "-" : map.name + " (" + map.width + "x" + map.height + ")"));
                            break;
                        case UnityEngine.Rendering.ShaderPropertyType.Color:
                            report.Add(name + " = " + material.GetColor(name));
                            break;
                        case UnityEngine.Rendering.ShaderPropertyType.Float:
                        case UnityEngine.Rendering.ShaderPropertyType.Range:
                            report.Add(name + " = " + material.GetFloat(name));
                            break;
                    }
                }
            }
        }
        File.WriteAllLines(path, report);
    }

    internal void Export(Transform root, string output, Func<Renderer, bool> filter = null, bool nativeSkin = false,
        List<Renderer> workspaceRenderers = null,
        Action<BinaryWriter, Renderer, int, Material, Dictionary<int, int>> workspaceMaterial = null)
    {
        var bones = root.GetComponentsInChildren<Transform>(true);
        var indices = new Dictionary<Transform, int>();
        for (int i = 0; i < bones.Length; i++)
            indices.Add(bones[i], i);
        var renderers = workspaceRenderers ?? ExportRenderers(root, filter);
        string partial = output + ".partial";
        var textures = new Dictionary<int, int>();
        using (var writer = new BinaryWriter(File.Create(partial)))
        {
            writer.Write(workspaceMaterial != null ? 0x3953434B : nativeSkin ? 0x3853434B : 0x3753434B);
            writer.Write(bones.Length);
            foreach (var bone in bones)
            {
                WriteText(writer, bone.name);
                bool top = bone == root;
                writer.Write(top ? -1 : indices[bone.parent]);
                WriteVector(writer, top ? Vector3.zero : bone.localPosition);
                Quaternion q = top ? Quaternion.identity : bone.localRotation;
                writer.Write(-q.x); writer.Write(-q.y); writer.Write(q.z); writer.Write(q.w);
                Vector3 scale = top ? Vector3.one : bone.localScale;
                writer.Write(scale.x); writer.Write(scale.y); writer.Write(scale.z);
            }
            writer.Write(renderers.Count);
            foreach (var renderer in renderers)
                WriteRenderer(writer, root, renderer, indices, textures, filter != null && IsBodyRenderer(renderer), nativeSkin,
                    workspaceMaterial);
        }
        if (File.Exists(output))
            File.Replace(partial, output, null);
        else
            File.Move(partial, output);
        Logger.LogInfo("Exported " + renderers.Count + " renderers, " + textures.Count + " material textures.");
    }

    internal static List<Renderer> ExportRenderers(Transform root, Func<Renderer, bool> filter = null)
    {
        var renderers = root.GetComponentsInChildren<Renderer>(false)
            .Where(renderer => IsRenderable(renderer) && (filter == null || filter(renderer))).ToList();
        if (!renderers.Any(IsBodyRenderer))
        {
            var body = root.GetComponentsInChildren<Renderer>(true)
                .Where(renderer => IsBodyRenderer(renderer) && (filter == null || filter(renderer)))
                .OrderByDescending(renderer => renderer.gameObject.activeInHierarchy)
                .ThenByDescending(renderer => renderer.name.Equals("o_body_a", StringComparison.OrdinalIgnoreCase))
                .FirstOrDefault();
            if (body != null)
                renderers.Add(body);
        }
        if (renderers.Count == 0)
            throw new InvalidDataException("The loaded card did not produce any visible meshes.");
        return renderers;
    }

    private static bool IsRenderable(Renderer renderer)
    {
        return renderer.enabled && !renderer.forceRenderingOff &&
            renderer.shadowCastingMode != UnityEngine.Rendering.ShadowCastingMode.ShadowsOnly &&
            renderer.name.IndexOf("shadowcaster", StringComparison.OrdinalIgnoreCase) < 0 &&
            SourceMesh(renderer) != null;
    }

    internal static bool IsWorkspaceMesh(Renderer renderer)
    {
        return renderer.shadowCastingMode != UnityEngine.Rendering.ShadowCastingMode.ShadowsOnly &&
            renderer.name.IndexOf("shadowcaster", StringComparison.OrdinalIgnoreCase) < 0 &&
            SourceMesh(renderer) != null;
    }

    private static bool IsBodyRenderer(Renderer renderer)
    {
        return renderer.name.StartsWith("o_body", StringComparison.OrdinalIgnoreCase)
            && SourceMesh(renderer) != null && renderer.shadowCastingMode != UnityEngine.Rendering.ShadowCastingMode.ShadowsOnly;
    }

    private static Mesh SourceMesh(Renderer renderer)
    {
        var skinned = renderer as SkinnedMeshRenderer;
        if (skinned != null)
            return skinned.sharedMesh;
        var filter = renderer.GetComponent<MeshFilter>();
        return renderer is MeshRenderer && filter != null ? filter.sharedMesh : null;
    }

    private void WriteRenderer(BinaryWriter writer, Transform root, Renderer renderer,
        Dictionary<Transform, int> indices, Dictionary<int, int> textures, bool maskOnly, bool nativeSkin,
        Action<BinaryWriter, Renderer, int, Material, Dictionary<int, int>> workspaceMaterial)
    {
        Mesh source = SourceMesh(renderer);
        var skinned = renderer as SkinnedMeshRenderer;
        var joints = skinned != null ? skinned.bones : new Transform[0];
        var bindPoses = nativeSkin && skinned != null ? source.bindposes : new Matrix4x4[0];
        bool useNative = bindPoses.Length > 0 && joints.Length == bindPoses.Length &&
            joints.All(joint => joint != null && indices.ContainsKey(joint)) &&
            source.boneWeights.Length == source.vertexCount;
        var baked = source;
        if (skinned != null && !useNative)
        {
            baked = new Mesh();
            skinned.BakeMesh(baked);
        }
        var vertices = baked.vertices;
        var normals = baked.normals;
        if (useNative)
            ApplyBlendShapes(skinned, vertices, normals);
        var uv = baked.uv;
        var weights = skinned != null ? source.boneWeights : new BoneWeight[0];
        // This Unity version includes the renderer scale in BakeMesh. The remaining transform is rigid.
        var geometryToWorld = skinned == null ? renderer.transform.localToWorldMatrix
            : Matrix4x4.TRS(renderer.transform.position, renderer.transform.rotation, Vector3.one);
        var geometryToRoot = useNative ? Matrix4x4.identity : root.worldToLocalMatrix * geometryToWorld;
        var normalToRoot = geometryToRoot.inverse.transpose;
        WriteText(writer, renderer.name);
        int count = maskOnly ? 3 : vertices.Length;
        writer.Write(count);
        for (int i = 0; i < count; i++)
        {
            WriteVector(writer, geometryToRoot.MultiplyPoint3x4(vertices[i]));
            WriteVector(writer, normals.Length == vertices.Length ? normalToRoot.MultiplyVector(normals[i]).normalized : Vector3.up);
            Vector2 texcoord = uv.Length == vertices.Length ? uv[i] : Vector2.zero;
            writer.Write(texcoord.x);
            writer.Write(1 - texcoord.y);
            int fallback = indices[renderer.transform];
            if (weights.Length == vertices.Length && joints.Length > 0)
            {
                var w = weights[i];
                writer.Write(useNative ? w.boneIndex0 : BoneId(w.boneIndex0, joints, indices, fallback));
                writer.Write(useNative ? w.boneIndex1 : BoneId(w.boneIndex1, joints, indices, fallback));
                writer.Write(useNative ? w.boneIndex2 : BoneId(w.boneIndex2, joints, indices, fallback));
                writer.Write(useNative ? w.boneIndex3 : BoneId(w.boneIndex3, joints, indices, fallback));
                writer.Write(w.weight0); writer.Write(w.weight1); writer.Write(w.weight2); writer.Write(w.weight3);
            }
            else
            {
                for (int j = 0; j < 4; j++) writer.Write(fallback);
                writer.Write(1f); writer.Write(0f); writer.Write(0f); writer.Write(0f);
            }
        }
        bool body = IsBodyRenderer(renderer);
        bool workspace = workspaceMaterial != null;
        var uv2 = (body || workspace) && !maskOnly ? source.uv2 : new Vector2[0];
        var uv3 = (body || workspace) && !maskOnly ? source.uv3 : new Vector2[0];
        var uv4 = (body || workspace) && !maskOnly ? source.uv4 : new Vector2[0];
        var colors = (body || workspace) && !maskOnly ? source.colors32 : new Color32[0];
        byte auxiliary = (byte)((uv2.Length == count ? 1 : 0) | (uv3.Length == count ? 2 : 0) | (uv4.Length == count ? 4 : 0));
        if (workspace)
        {
            writer.Write((byte)(auxiliary | (colors.Length == count ? 8 : 0)));
            foreach (var layer in new[] { uv2, uv3, uv4 })
                if (layer.Length == count)
                    foreach (var coords in layer)
                    {
                        writer.Write(coords.x);
                        writer.Write(1 - coords.y);
                    }
            if (colors.Length == count)
                foreach (var color in colors)
                {
                    writer.Write(color.r); writer.Write(color.g); writer.Write(color.b); writer.Write(color.a);
                }
        }
        else
        {
            writer.Write(auxiliary);
            if (auxiliary != 0)
            {
                var layers = new[] { uv2, uv3, uv4 };
                for (int i = 0; i < count; i++)
                {
                    foreach (var layer in layers)
                    {
                        var coords = layer.Length == count ? layer[i] : Vector2.zero;
                        writer.Write(coords.x);
                        writer.Write(1 - coords.y);
                    }
                    writer.Write(colors.Length == count ? colors[i].r : (byte)255);
                    writer.Write(colors.Length == count ? colors[i].b : (byte)255);
                }
            }
        }
        var materials = renderer.sharedMaterials;
        int surfaces = maskOnly ? 1 : baked.subMeshCount;
        writer.Write(surfaces);
        for (int i = 0; i < surfaces; i++)
        {
            var material = materials.Length == 0 ? null : materials[Math.Min(i, materials.Length - 1)];
            if (workspace)
                workspaceMaterial(writer, renderer, i, material, textures);
            else
                WriteMaterial(writer, i < materials.Length ? material : null, textures, maskOnly, body, auxiliary, nativeSkin);
            int[] triangles = maskOnly ? new[] { 0, 1, 2 } : baked.GetTriangles(i);
            writer.Write(triangles.Length);
            for (int j = 0; j < triangles.Length; j += 3)
            {
                writer.Write(triangles[j]); writer.Write(triangles[j + 2]); writer.Write(triangles[j + 1]);
            }
        }
        if (baked != source)
            Destroy(baked);
        if (nativeSkin)
        {
            writer.Write(useNative ? bindPoses.Length : 0);
            if (useNative)
            {
                for (int j = 0; j < bindPoses.Length; j++)
                {
                    writer.Write(indices[joints[j]]);
                    var bind = bindPoses[j];
                    WriteVector(writer, bind.GetColumn(0));
                    WriteVector(writer, bind.GetColumn(1));
                    WriteVector(writer, -bind.GetColumn(2));
                    WriteVector(writer, bind.GetColumn(3));
                }
            }
        }
    }

    private static void ApplyBlendShapes(SkinnedMeshRenderer renderer, Vector3[] vertices, Vector3[] normals)
    {
        var mesh = renderer.sharedMesh;
        if (mesh.blendShapeCount == 0)
            return;
        var positions = new Vector3[vertices.Length];
        var directions = new Vector3[vertices.Length];
        var tangents = new Vector3[vertices.Length];
        for (int shape = 0; shape < mesh.blendShapeCount; shape++)
        {
            float weight = renderer.GetBlendShapeWeight(shape);
            int frames = mesh.GetBlendShapeFrameCount(shape);
            if (Mathf.Abs(weight) < 0.0001f || frames == 0)
                continue;
            int upper = 0;
            while (upper + 1 < frames && weight > mesh.GetBlendShapeFrameWeight(shape, upper))
                upper++;
            float upperWeight = mesh.GetBlendShapeFrameWeight(shape, upper);
            float lowerWeight = upper > 0 ? mesh.GetBlendShapeFrameWeight(shape, upper - 1) : 0f;
            float blend = Mathf.Approximately(upperWeight, lowerWeight) ? 1f : (weight - lowerWeight) / (upperWeight - lowerWeight);
            mesh.GetBlendShapeFrameVertices(shape, upper, positions, directions, tangents);
            for (int i = 0; i < vertices.Length; i++)
            {
                vertices[i] += positions[i] * blend;
                if (normals.Length == vertices.Length)
                    normals[i] += directions[i] * blend;
            }
            if (upper == 0 || Mathf.Approximately(blend, 1f))
                continue;
            mesh.GetBlendShapeFrameVertices(shape, upper - 1, positions, directions, tangents);
            for (int i = 0; i < vertices.Length; i++)
            {
                vertices[i] += positions[i] * (1f - blend);
                if (normals.Length == vertices.Length)
                    normals[i] += directions[i] * (1f - blend);
            }
        }
    }

    private static int BoneId(int index, Transform[] bones, Dictionary<Transform, int> indices, int fallback)
    {
        int id;
        return index < bones.Length && bones[index] != null && indices.TryGetValue(bones[index], out id) ? id : fallback;
    }

    private static void WriteMaterial(BinaryWriter writer, Material source, Dictionary<int, int> textures, bool maskOnly, bool body, byte auxiliary, bool studio)
    {
        string shader = source != null && source.shader != null ? source.shader.name.ToLowerInvariant() : "";
        int queue = source != null ? source.renderQueue : 2000;
        bool skin = body || shader.Contains("main_skin");
        bool hair = shader.Contains("hair");
        bool eye = shader.Contains("main_eye") || shader.Contains("main_nose");
        string baseSlot = "_MainTex";
        Texture main = MaterialTexture(source, baseSlot);
        if (skin && main == null)
        {
            baseSlot = "_BaseMap";
            main = MaterialTexture(source, baseSlot);
        }
        Texture mask = MaterialTexture(source, "_ColorMask");
        Texture clothingMask = skin ? MaterialTexture(source, "_AlphaMask") : null;
        float maskUse = MaterialFloat(source, "_ColorMaskUse", 1);
        bool hasBakedClothes = main != null && shader.Contains("clothes") &&
            (maskUse < 0.5f || main is RenderTexture);
        Color color = skin || hasBakedClothes ? Color.white : MaterialColor(source, "_Color", Color.white);
        byte opacity = (byte)(eye || color.a < 0.99f || (!hair && queue >= 3000) ? 2 :
            hair || clothingMask != null || shader.Contains("alpha") || shader.Contains("cutout") ? 1 : 0);
        if (studio && shader.StartsWith("shader forge/main_opaque", StringComparison.Ordinal))
            opacity = (byte)(source.GetTag("RenderType", false) == "TransparentCutout" || clothingMask != null ? 1 : 0);
        writer.Write((byte)(skin ? 1 : hair ? 2 : eye ? 3 : 0));
        writer.Write(opacity);
        writer.Write(queue);
        writer.Write(MaterialFloat(source, "_Cutoff", 0.5f));
        writer.Write(MaterialFloat(source, "_ShadowExtend", 0.48f));
        WriteColor(writer, color);
        WriteColor(writer, MaterialFloat(source, "_Color2onoff", 1) > 0.5f ?
            MaterialColor(source, "_Color2", color) : color);
        WriteColor(writer, MaterialFloat(source, "_Color3onoff", 1) > 0.5f ?
            MaterialColor(source, "_Color3", color) : color);
        WriteColor(writer, MaterialColor(source, "_ShadowColor",
            MaterialColor(source, "_shadowcolor", new Color(0.84f, 0.85f, 0.91f))));
        WriteColor(writer, MaterialColor(source, "_GlossColor", Color.white));
        for (int i = 1; i <= 3; i++)
            WriteColor(writer, MaterialColor(source, "_overcolor" + i, Color.clear));

        WriteMaterialTexture(writer, textures, source, baseSlot, maskOnly ? null : main, false, skin ? 4096 : 2048);
        WriteMaterialTexture(writer, textures, source, "_ColorMask",
            !maskOnly && (hair || (!hasBakedClothes && maskUse >= 0.5f)) ? mask : null, true, 1024);
        WriteMaterialTexture(writer, textures, source, "_HairGloss", hair ? MaterialTexture(source, "_HairGloss") : null, true, 1024);
        for (int i = 1; i <= 3; i++)
        {
            bool hairDetail = hair && i == 1;
            string name = hairDetail ? "_DetailMask" : "_overtex" + i;
            bool skinLayer = skin && (!body || (auxiliary & (1 << (i - 1))) != 0);
            string uvSlot = "_texcoord" + (i + 1);
            if (!body || !skinLayer || source == null || !source.HasProperty(uvSlot))
                uvSlot = name;
            WriteMaterialTexture(writer, textures, source, uvSlot,
                !maskOnly && (skinLayer || eye || hairDetail) ? MaterialTexture(source, name) : null, hairDetail, 1024);
        }
        writer.Write(MaterialFloat(source, "_alpha_a", 1));
        writer.Write(MaterialFloat(source, "_alpha_b", 1));
        WriteMaterialTexture(writer, textures, source, "_AlphaMask", clothingMask, true, 1024);
        writer.Write(MaterialFloat(source, "_NormalMapScale", MaterialFloat(source, "_BumpScale", 1)));
        writer.Write(MaterialFloat(source, "_DetailNormalMapScale", 0.4f));
        writer.Write(MaterialFloat(source, "_FaceNormalG", 0));
        writer.Write(MaterialFloat(source, "_SpecularPower", 0));
        writer.Write(MaterialFloat(source, "_DetailRLineR", 0));
        writer.Write(MaterialFloat(source, "_DetailBLineG", 0));
        writer.Write(new[] { "_liquidftop", "_liquidfbot", "_liquidbtop", "_liquidbbot", "_liquidface" }
            .Max(name => MaterialFloat(source, name, 0)));
        foreach (string name in new[] {
            "_NormalMap", "_NormalMapDetail", "_DetailMask", "_LineMask",
            "_NormalMask", "_AnotherRamp", "_liquidmask", "_Texture2"
        })
        {
            string slot = name == "_NormalMap" && MaterialTexture(source, name) == null ? "_BumpMap" : name;
            bool enabled = !maskOnly && (name != "_LineMask" || MaterialFloat(source, "_linetexon", 1) > 0.5f);
            WriteMaterialTexture(writer, textures, source, slot, enabled ? MaterialTexture(source, slot) : null, true, 2048);
        }
        if (auxiliary != 0)
        {
            writer.Write(MaterialFloat(source, "_nip", 0));
            writer.Write(MaterialFloat(source, "_nipsize", 0.5f));
            writer.Write(MaterialFloat(source, "_tex1mask", 0));
            writer.Write(MaterialFloat(source, "_nip_specular", 0));
        }
    }

    private static Texture MaterialTexture(Material source, string name)
    {
        return source != null && source.HasProperty(name) ? source.GetTexture(name) : null;
    }

    private static float MaterialFloat(Material source, string name, float fallback)
    {
        return source != null && source.HasProperty(name) ? source.GetFloat(name) : fallback;
    }

    private static Color MaterialColor(Material source, string name, Color fallback)
    {
        return source != null && source.HasProperty(name) ? source.GetColor(name) : fallback;
    }

    internal static void WriteColor(BinaryWriter writer, Color color)
    {
        writer.Write(color.r); writer.Write(color.g); writer.Write(color.b); writer.Write(color.a);
    }

    internal static void WriteMaterialTexture(BinaryWriter writer, Dictionary<int, int> textures,
        Material material, string slot, Texture texture, bool linear, int maxSize)
    {
        if (texture == null)
        {
            writer.Write(-1);
            return;
        }
        Vector2 scale = material.GetTextureScale(slot);
        Vector2 offset = material.GetTextureOffset(slot);
        int key = unchecked(texture.GetInstanceID() * 2 + (linear ? 1 : 0));
        int existing;
        if (textures.TryGetValue(key, out existing))
        {
            writer.Write(existing);
            writer.Write(0);
            WriteUv(writer, scale, offset);
            return;
        }
        int index = textures.Count;
        textures.Add(key, index);
        int width = Mathf.Min(maxSize, texture.width);
        int height = Mathf.Min(maxSize, texture.height);
        var buffer = RenderTexture.GetTemporary(width, height, 0, RenderTextureFormat.ARGB32,
            linear ? RenderTextureReadWrite.Linear : RenderTextureReadWrite.Default);
        var old = RenderTexture.active;
        var image = new Texture2D(width, height, TextureFormat.RGBA32, false, linear);
        try
        {
            Graphics.Blit(texture, buffer);
            RenderTexture.active = buffer;
            image.ReadPixels(new Rect(0, 0, width, height), 0, 0);
            byte[] png = image.EncodeToPNG();
            writer.Write(index);
            writer.Write(png.Length);
            writer.Write(png);
            WriteUv(writer, scale, offset);
        }
        finally
        {
            RenderTexture.active = old;
            RenderTexture.ReleaseTemporary(buffer);
            Destroy(image);
        }
    }

    private static void WriteUv(BinaryWriter writer, Vector2 scale, Vector2 offset)
    {
        writer.Write(scale.x); writer.Write(scale.y);
        writer.Write(offset.x); writer.Write(1 - scale.y - offset.y);
    }

    internal static void WriteText(BinaryWriter writer, string text)
    {
        byte[] data = Encoding.UTF8.GetBytes(text);
        writer.Write(data.Length);
        writer.Write(data);
    }

    private static void WriteVector(BinaryWriter writer, Vector3 v)
    {
        writer.Write(v.x); writer.Write(v.y); writer.Write(-v.z);
    }
}
