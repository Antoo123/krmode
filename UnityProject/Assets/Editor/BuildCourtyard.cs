using System;
using System.IO;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class BuildCourtyard
{
    [MenuItem("Courtyard/Build Windows x64")]
    public static void Windows()
    {
        string output = Path.GetFullPath(Path.Combine(Application.dataPath, "../../Build/UnityWindows/Courtyard.exe"));
        Directory.CreateDirectory(Path.GetDirectoryName(output));
        var options = new BuildPlayerOptions
        {
            scenes = new[] { "Assets/Courtyard.unity" },
            locationPathName = output,
            target = BuildTarget.StandaloneWindows64
        };
        BuildReport report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != BuildResult.Succeeded)
            throw new BuildFailedException($"Windows build: {report.summary.result} ({report.summary.totalErrors} errors).");
        Debug.Log($"Courtyard Windows build: {output}");
    }
}
