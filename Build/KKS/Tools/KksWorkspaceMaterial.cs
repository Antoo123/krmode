using System;
using System.Collections.Generic;
using System.IO;
using UnityEngine;
using UnityEngine.Rendering;

internal static class KksWorkspaceMaterial
{
    internal static readonly string[] Parameters = {
        "base_tint", "tint_2", "tint_3", "emission_tint", "cutoff", "base_uv"
    };

    private static string Property(Material source, ShaderPropertyType type, ShaderPropertyFlags flag, params string[] names)
    {
        if (source == null || source.shader == null)
            return null;
        if (flag != ShaderPropertyFlags.None)
            for (int i = 0; i < source.shader.GetPropertyCount(); i++)
                if (source.shader.GetPropertyType(i) == type && (source.shader.GetPropertyFlags(i) & flag) != 0)
                    return source.shader.GetPropertyName(i);
        foreach (string name in names)
        {
            int index = source.shader.FindPropertyIndex(name);
            if (index >= 0 && source.shader.GetPropertyType(index) == type)
                return name;
        }
        return null;
    }

    internal static string BaseMap(Material source)
    {
        return Property(source, ShaderPropertyType.Texture, ShaderPropertyFlags.MainTexture, "_MainTex", "_BaseMap", "_Albedo", "_Texture");
    }

    internal static string BaseColor(Material source)
    {
        return Property(source, ShaderPropertyType.Color, ShaderPropertyFlags.MainColor, "_BaseColor", "_Color", "_Albedo", "_Tint", "_TintColor");
    }

    internal static float Float(Material source, string slot, float fallback)
    {
        return source != null && source.HasProperty(slot) ? source.GetFloat(slot) : fallback;
    }

    private static Color ColorValue(Material source, MaterialPropertyBlock block, string slot, Color fallback)
    {
        if (slot == null || source == null || !source.HasProperty(slot))
            return fallback;
        // This Unity version can read a block value but cannot distinguish an unset value from zero.
        var value = !block.isEmpty ? block.GetColor(slot) : Color.clear;
        return value != Color.clear ? value : source.GetColor(slot);
    }

    internal static Vector4 Sample(Material source, MaterialPropertyBlock block, int channel)
    {
        switch (channel)
        {
            case 0:
                var color = ColorValue(source, block, BaseColor(source), Color.white);
                color.a = IsGoo(source) ? Float(source, "_Alpha", 1) :
                    color.a * Float(source, "_Alpha", Float(source, "_alpha", 1));
                return color;
            case 1:
                return Float(source, "_Color2onoff", 1) > 0.5f ?
                    ColorValue(source, block, "_Color2", Color.white) : Color.white;
            case 2:
                return Float(source, "_Color3onoff", 1) > 0.5f ?
                    ColorValue(source, block, "_Color3", Color.white) : Color.white;
            case 3:
                return ColorValue(source, block, "_EmissionColor", Color.white * Float(source, "_EmissionPower", 0));
            case 4:
                return new Vector4(Float(source, "_Cutoff", 0.5f), 0, 0, 0);
            default:
                var slot = BaseMap(source);
                if (slot == null)
                    return new Vector4(1, 1, 0, 0);
                var scale = source.GetTextureScale(slot);
                var offset = source.GetTextureOffset(slot);
                var transform = !block.isEmpty ? block.GetVector(slot + "_ST") : Vector4.zero;
                return transform != Vector4.zero
                    ? new Vector4(transform.x, transform.y, transform.z, 1 - transform.y - transform.w)
                    : new Vector4(scale.x, scale.y, offset.x, 1 - scale.y - offset.y);
        }
    }

    internal static void ReadBlock(Renderer renderer, int index, MaterialPropertyBlock block)
    {
        renderer.GetPropertyBlock(block, index);
        if (block.isEmpty)
            renderer.GetPropertyBlock(block);
    }

    private static bool IsGoo(Material source)
    {
        return source != null && source.HasProperty("_FresnelScale") && source.HasProperty("_FresnelAlpha") &&
            source.HasProperty("_FresnelBias") && source.HasProperty("_MatcapAlpha") && source.HasProperty("_Sh") &&
            source.HasProperty("_Albedo");
    }

    internal static void Write(BinaryWriter writer, Renderer renderer, int index, Material source,
        Dictionary<int, int> textures)
    {
        var block = new MaterialPropertyBlock();
        if (index < renderer.sharedMaterials.Length)
            ReadBlock(renderer, index, block);
        var shader = source != null && source.shader != null ? source.shader.name : "";
        var tag = source != null ? source.GetTag("RenderType", false) : "";
        bool goo = IsGoo(source);
        int queue = source != null ? source.renderQueue : 2000;
        var tint = Sample(source, block, 0);
        int mode = (int)Float(source, "_Mode", -1);
        bool unlit = shader.IndexOf("unlit", StringComparison.OrdinalIgnoreCase) >= 0;
        bool cutout = mode == 1 || tag == "TransparentCutout" ||
            (source != null && source.IsKeywordEnabled("_ALPHATEST_ON"));
        bool transparent = !cutout && (mode == 2 || mode == 3 || tag == "Transparent" || queue >= 2900 || tint.w < 0.999f);
        var src = (BlendMode)Float(source, "_SrcBlend", mode == 3 ? 1 : 5);
        var dst = (BlendMode)Float(source, "_DstBlend", 10);
        var operation = (BlendOp)Float(source, "_BlendOp", 0);
        int blend = !transparent ? (cutout ? 1 : 0) :
            operation == BlendOp.Subtract || operation == BlendOp.ReverseSubtract ? 4 :
            dst == BlendMode.One ? 3 : src == BlendMode.DstColor || dst == BlendMode.SrcColor ? 5 :
            src == BlendMode.One && dst == BlendMode.OneMinusSrcAlpha ? 6 : 2;
        var cull = (CullMode)Float(source, "_Cull", Float(source, "_CullMode", 2));
        bool depth = Float(source, "_ZWrite", transparent && !goo ? 0 : 1) > 0.5f;
        bool noDepthTest = (CompareFunction)Float(source, "_ZTest", 4) == CompareFunction.Always;
        bool colors = shader.IndexOf("particle", StringComparison.OrdinalIgnoreCase) >= 0 ||
            shader.IndexOf("vertex color", StringComparison.OrdinalIgnoreCase) >= 0 ||
            Float(source, "_VertexColor", Float(source, "_UseVertexColor", 0)) > 0.5f;
        bool toon = shader.StartsWith("Shader Forge/", StringComparison.OrdinalIgnoreCase);

        KksCardCapture.WriteText(writer, shader);
        writer.Write(queue);
        writer.Write((byte)blend);
        writer.Write((byte)cull);
        writer.Write((byte)((depth ? 1 : 0) | (unlit ? 2 : 0) | (colors ? 4 : 0) | (toon ? 8 : 0) |
            (goo ? 16 : 0) | (noDepthTest ? 32 : 0)));
        for (int channel = 0; channel < Parameters.Length; channel++)
            KksCardCapture.WriteColor(writer, Sample(source, block, channel));
        writer.Write(Float(source, "_Metallic", 0));
        writer.Write(Float(source, "_Smoothness", Float(source, "_Glossiness", 0.35f)));
        writer.Write(Float(source, "_BumpScale", Float(source, "_NormalMapScale", 1)));
        KksCardCapture.WriteColor(writer, ColorValue(source, block, "_ShadowColor",
            ColorValue(source, block, "_shadowcolor", new Color(0.84f, 0.85f, 0.91f))));
        writer.Write(Float(source, "_ShadowExtend", 0.48f));
        writer.Write(Float(source, "_SpecularPower", 0.5f));
        if (goo)
        {
            writer.Write(Float(source, "_FresnelScale", 1));
            writer.Write(Float(source, "_FresnelPower", 2));
            writer.Write(Float(source, "_FresnelAlpha", 0));
            writer.Write(Float(source, "_FresnelBias", 0));
            writer.Write(Float(source, "_Sh", 0));
            writer.Write(Float(source, "_MatcapAlpha", 0));
            writer.Write(Float(source, "_alpha_a", 1));
            writer.Write(Float(source, "_alpha_b", 1));
        }

        WriteMap(writer, textures, source, block, BaseMap(source), false);
        WriteMap(writer, textures, source, block, Float(source, "_ColorMaskUse", 1) < 0.5f ? null :
            Property(source, ShaderPropertyType.Texture, ShaderPropertyFlags.None, "_ColorMask"), true);
        WriteMap(writer, textures, source, block, Property(source, ShaderPropertyType.Texture, ShaderPropertyFlags.Normal, "_BumpMap", "_NormalMap"), true);
        WriteMap(writer, textures, source, block, Property(source, ShaderPropertyType.Texture, ShaderPropertyFlags.None, "_EmissionMap"), false);
        WriteMap(writer, textures, source, block, toon ? "_DetailMask" : null, true);
        WriteMap(writer, textures, source, block, goo ? "_Matcap" : null, false);
        WriteMap(writer, textures, source, block, goo ? "_AlphaMask" : null, true);
    }

    private static void WriteMap(BinaryWriter writer, Dictionary<int, int> textures,
        Material material, MaterialPropertyBlock block, string slot, bool linear)
    {
        var map = slot != null && material != null && material.HasProperty(slot)
            ? (block.isEmpty ? null : block.GetTexture(slot)) ?? material.GetTexture(slot) : null;
        if (map != null && map.dimension != TextureDimension.Tex2D)
            map = null;
        writer.Write((byte)(map != null ? (int)map.filterMode : 1));
        writer.Write((byte)(map != null ? (int)map.wrapModeU : 0));
        writer.Write((byte)(map != null ? (int)map.wrapModeV : 0));
        KksCardCapture.WriteMaterialTexture(writer, textures, material, slot, map, linear, 4096);
    }
}
