using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using UnityEngine;

internal sealed class KksStudioVisualCapture : IDisposable
{
    private const int RowVertices = 256;
    private const int TexelPairBytes = 16;
    private const int MaxAtlasHeight = 8192;
    private const long MaxCaptureBytes = 256L * 1024 * 1024;
    private readonly Transform root;
    private readonly Entry[] entries;
    private readonly Mesh baked = new Mesh();
    private readonly int frames;
    private readonly SkinEffect[] skinEffects;

    private sealed class Entry
    {
        public int index;
        public SkinnedMeshRenderer renderer;
        public int count;
        public int rows;
        public byte[] pixels;
        public byte[] visible;
    }

    private sealed class SkinEffect
    {
        public int renderer;
        public int surface;
        public Material material;
        public Vector4[] clock;
    }

    public KksStudioVisualCapture(Transform root, int frames, List<Renderer> workspaceRenderers = null)
    {
        this.root = root;
        this.frames = frames;
        var cached = new List<Entry>();
        long allocated = 0;
        var renderers = workspaceRenderers ?? KksCardCapture.ExportRenderers(root);
        for (int index = 0; index < renderers.Count; index++)
        {
            if (!NeedsVertexCapture(renderers[index]))
                continue;
            var renderer = (SkinnedMeshRenderer)renderers[index];
            int count = renderer.sharedMesh.vertexCount;
            int rows = (count + RowVertices - 1) / RowVertices;
            long size = (long)frames * rows * RowVertices * TexelPairBytes;
            // Meshes outside the texture budget retain their original skeletal playback.
            if (rows * frames > MaxAtlasHeight || allocated + size > MaxCaptureBytes)
                continue;
            cached.Add(new Entry {
                index = index, renderer = renderer, count = count, rows = rows,
                pixels = new byte[(int)size], visible = new byte[frames]
            });
            allocated += size;
        }
        entries = cached.ToArray();
        skinEffects = entries.SelectMany(entry => entry.renderer.sharedMaterials.Select((material, surface) =>
            new SkinEffect { renderer = entry.index, surface = surface, material = material, clock = new Vector4[frames] }))
            .Where(effect => effect.material != null && effect.material.HasProperty("_DisplaceTex") &&
                effect.material.shader.name.StartsWith("xukmi/SkinPlusTess", StringComparison.Ordinal)).ToArray();
    }

    private static bool NeedsVertexCapture(Renderer renderer)
    {
        var mesh = renderer as SkinnedMeshRenderer;
        if (mesh == null)
            return false;
        string name = mesh.name;
        if (name.StartsWith("cf_O", StringComparison.Ordinal) || name.StartsWith("o_body", StringComparison.OrdinalIgnoreCase)
            || name.Equals("o_tang", StringComparison.OrdinalIgnoreCase))
            return true;
        for (var part = renderer.transform; part != null; part = part.parent)
            if (part.name.StartsWith("ct_clothes", StringComparison.OrdinalIgnoreCase) ||
                part.name.StartsWith("ct_shorts", StringComparison.OrdinalIgnoreCase) ||
                part.name.StartsWith("ct_bra", StringComparison.OrdinalIgnoreCase) ||
                part.name.StartsWith("ct_panst", StringComparison.OrdinalIgnoreCase))
                return true;
        return false;
    }

    public void Sample(int frame)
    {
        foreach (var effect in skinEffects)
            effect.clock[frame] = effect.material.GetVector("_Clock");
        foreach (var entry in entries)
        {
            var renderer = entry.renderer;
            entry.visible[frame] = (byte)(renderer.enabled && !renderer.forceRenderingOff && renderer.gameObject.activeInHierarchy ? 1 : 0);
            renderer.BakeMesh(baked);
            var positions = baked.vertices;
            var normals = baked.normals;
            if (positions.Length != entry.count || normals.Length != entry.count)
                throw new InvalidDataException("Mesh layout changed during the scene: " + renderer.name);
            // This Studio uses the scaled BakeMesh snapshot. Move the result into actor space.
            var local = root.worldToLocalMatrix * Matrix4x4.TRS(renderer.transform.position, renderer.transform.rotation, Vector3.one);
            var normalMatrix = local.inverse.transpose;
            int offset = frame * entry.rows * RowVertices * TexelPairBytes;
            using (var writer = new BinaryWriter(new MemoryStream(entry.pixels, offset, entry.rows * RowVertices * TexelPairBytes, true)))
            {
                for (int i = 0; i < entry.count; i++)
                {
                    WriteTexel(writer, local.MultiplyPoint3x4(positions[i]));
                    WriteTexel(writer, normalMatrix.MultiplyVector(normals[i]).normalized);
                }
            }
        }
    }

    public void Save(string path)
    {
        using (var writer = new BinaryWriter(new GZipStream(File.Create(path), CompressionMode.Compress)))
        {
            writer.Write(0x3156534b); // KSV1. Pairs of RGBA16F position and normal texels.
            writer.Write(frames);
            writer.Write(entries.Length);
            foreach (var entry in entries)
            {
                writer.Write(entry.index);
                writer.Write(entry.count);
                writer.Write(entry.rows);
                writer.Write(entry.visible);
                writer.Write(entry.pixels);
            }
            WriteSkinEffects(writer);
        }
    }

    private void WriteSkinEffects(BinaryWriter writer)
    {
        writer.Write(0x314d534b); // KSM1. Optional SkinPlus extension of the cache.
        writer.Write(skinEffects.Length);
        var textures = new Dictionary<int, int>();
        foreach (var effect in skinEffects)
        {
            var material = effect.material;
            writer.Write(effect.renderer);
            writer.Write(effect.surface);
            writer.Write(material.GetFloat("_DisplaceMultiplier"));
            writer.Write(material.GetFloat("_DisplaceFull"));
            bool multiplyMatcap = material.HasProperty("_ReflectionMapCap") &&
                material.GetFloat("_UseMatCapReflection") > 0.999f &&
                Mathf.FloorToInt(material.GetFloat("_ReflBlendSrc")) == 2 &&
                Mathf.FloorToInt(material.GetFloat("_ReflBlendDst")) == 0 &&
                material.GetTexture("_ReflectMap") == null;
            writer.Write(multiplyMatcap ? material.GetFloat("_ReflectionVal") : 0f);
            foreach (var clock in effect.clock)
            {
                writer.Write(clock.x); writer.Write(-clock.y); writer.Write(clock.w);
            }
            KksCardCapture.WriteMaterialTexture(writer, textures, material, "_DisplaceTex",
                material.GetTexture("_DisplaceTex"), true, 2048);
            if (multiplyMatcap)
                KksCardCapture.WriteMaterialTexture(writer, textures, material, "_ReflectionMapCap",
                    material.GetTexture("_ReflectionMapCap"), true, 1024);
            else
                writer.Write(-1);
        }
    }

    private static void WriteTexel(BinaryWriter writer, Vector3 value)
    {
        writer.Write(Mathf.FloatToHalf(value.x));
        writer.Write(Mathf.FloatToHalf(value.y));
        writer.Write(Mathf.FloatToHalf(-value.z));
        writer.Write((ushort)0);
    }

    public void Dispose()
    {
        UnityEngine.Object.Destroy(baked);
    }

    internal static void Describe(Transform root, TextWriter report, int actor, int frame)
    {
        foreach (var mesh in KksCardCapture.ExportRenderers(root))
        {
            if (frame != 0 && !mesh.name.StartsWith("o_body", StringComparison.OrdinalIgnoreCase) && mesh.name != "cf_O_face")
                continue;
            DescribeRenderer(mesh, report, actor, frame);
        }
    }

    internal static void DescribeRenderer(Renderer mesh, TextWriter report, int actor, int frame)
    {
            foreach (var material in mesh.sharedMaterials.Where(m => m != null))
            {
                report.WriteLine("{0}\t{1}\t{2}\t{3}\t{4}\t{5}\t{6}", actor, frame, mesh.name,
                    material.shader.name, material.renderQueue, material.GetTag("RenderType", false),
                    String.Join(",", mesh.GetComponents<Component>().Select(component => component.GetType().Name).ToArray()));
                for (int i = 0; i < material.shader.GetPropertyCount(); i++)
                {
                    string name = material.shader.GetPropertyName(i);
                    string type = material.shader.GetPropertyType(i).ToString();
                    if (frame != 0 && type == "Texture") continue;
                    string value;
                    switch (type)
                    {
                        case "Texture":
                            var texture = material.GetTexture(name);
                            value = texture == null ? "-" : texture.name + " (" + texture.width + "x" + texture.height + ")";
                            break;
                        case "Vector":
                        case "Color":
                            var vector = material.GetVector(name);
                            value = String.Format(CultureInfo.InvariantCulture, "{0:R},{1:R},{2:R},{3:R}", vector.x, vector.y, vector.z, vector.w);
                            break;
                        default:
                            value = material.GetFloat(name).ToString("R", CultureInfo.InvariantCulture);
                            break;
                    }
                    report.WriteLine("\t{0}\t{1}\t{2}", name, type, value);
                }
            }
    }
}
