using UnityEngine;
using UnityEngine.Rendering;

public sealed class Courtyard : MonoBehaviour
{
    private readonly Color sandstone = new Color32(223, 172, 137, 255);
    private CharacterController player;
    private Transform playerModel;
    private Camera followCamera;
    private Animation movement;
    private float yaw;
    private float pitch = 16;
    private float fallSpeed;

    private void Start()
    {
        Application.targetFrameRate = 60;
        RenderSettings.ambientMode = AmbientMode.Flat;
        RenderSettings.ambientLight = new Color32(190, 171, 177, 255);
        var sun = new GameObject("Sun").AddComponent<Light>();
        sun.type = LightType.Directional;
        sun.color = new Color32(255, 238, 216, 255);
        sun.intensity = 1.2f;
        sun.shadows = LightShadows.Soft;
        sun.transform.rotation = Quaternion.Euler(47, -38, 0);
        MakeLocation();

        var actor = new GameObject("Player");
        actor.layer = 2;
        actor.transform.position = new Vector3(0, 0.05f, -5.5f);
        player = actor.AddComponent<CharacterController>();
        player.height = 1.72f;
        player.radius = 0.3f;
        player.center = Vector3.up * 0.86f;
        player.stepOffset = 0.2f;
        playerModel = MakeCharacter(actor.transform, false);
        movement = playerModel.GetComponent<Animation>();
        movement.Play("Idle");

        var npc = new GameObject("Dancer");
        npc.transform.SetPositionAndRotation(new Vector3(0, 0.03f, 0.95f), Quaternion.Euler(0, 180, 0));
        var capsule = npc.AddComponent<CapsuleCollider>();
        capsule.radius = 0.3f;
        capsule.height = 1.72f;
        capsule.center = Vector3.up * 0.86f;
        MakeCharacter(npc.transform, true).GetComponent<Animation>().Play("Dance");

        followCamera = new GameObject("Follow Camera").AddComponent<Camera>();
        followCamera.gameObject.AddComponent<AudioListener>();
        followCamera.clearFlags = CameraClearFlags.SolidColor;
        followCamera.backgroundColor = new Color32(231, 180, 158, 255);
        followCamera.fieldOfView = 61;
        followCamera.nearClipPlane = 0.06f;
        UpdateCamera(1);
        Cursor.lockState = CursorLockMode.Locked;
    }

    private void Update()
    {
        if (Input.GetKeyDown(KeyCode.Escape))
            Cursor.lockState = CursorLockMode.None;
        if (Input.GetMouseButtonDown(0))
            Cursor.lockState = CursorLockMode.Locked;

        var direction = Vector3.zero;
        if (Cursor.lockState == CursorLockMode.Locked)
        {
            yaw += Input.GetAxisRaw("Mouse X") * 4;
            pitch = Mathf.Clamp(pitch - Input.GetAxisRaw("Mouse Y") * 4, -7, 59);
            direction.x = (Input.GetKey(KeyCode.D) ? 1 : 0) - (Input.GetKey(KeyCode.A) ? 1 : 0);
            direction.z = (Input.GetKey(KeyCode.W) ? 1 : 0) - (Input.GetKey(KeyCode.S) ? 1 : 0);
        }

        float dt = Time.deltaTime;
        Vector3 motion = Quaternion.Euler(0, yaw, 0) * Vector3.ClampMagnitude(direction, 1);
        fallSpeed = player.isGrounded ? -2 : fallSpeed - 16 * dt;
        player.Move((motion * 3.8f + Vector3.up * fallSpeed) * dt);
        string clip = "Idle";
        if (motion.sqrMagnitude > 0.001f)
        {
            playerModel.rotation = Quaternion.Slerp(playerModel.rotation, Quaternion.LookRotation(motion),
                1 - Mathf.Exp(-15 * dt));
            if (Vector3.ProjectOnPlane(player.velocity, Vector3.up).sqrMagnitude > 0.01f)
                clip = "Walk";
        }
        if (!movement.IsPlaying(clip))
            movement.CrossFade(clip, 0.16f);
    }

    private void LateUpdate()
    {
        UpdateCamera(1 - Mathf.Exp(-16 * Time.deltaTime));
    }

    private void UpdateCamera(float weight)
    {
        var focus = player.transform.position + Vector3.up * 1.36f;
        var offset = Quaternion.Euler(pitch, yaw, 0) * new Vector3(0.57f, 0, -4.1f);
        var goal = focus + offset;
        RaycastHit hit;
        if (Physics.Linecast(focus, goal, out hit, 1, QueryTriggerInteraction.Ignore))
            goal = Vector3.MoveTowards(hit.point, focus, 0.18f);
        var position = Vector3.Lerp(followCamera.transform.position, goal, weight);
        if (Physics.Linecast(focus, position, out hit, 1, QueryTriggerInteraction.Ignore))
            position = Vector3.MoveTowards(hit.point, focus, 0.18f);
        followCamera.transform.position = position;
        followCamera.transform.LookAt(focus + Vector3.up * 0.08f);
    }

    private void OnGUI()
    {
        var rect = new Rect(20, 20, 390, 44);
        GUI.Box(rect, GUIContent.none);
        GUI.Label(new Rect(33, 31, 369, 25), "WASD   Ходьба     Мышь   Камера     Esc   Курсор");
    }

    private void MakeLocation()
    {
        Part(transform, PrimitiveType.Cube, new Vector3(0, -0.26f, 0), new Vector3(17, 0.5f, 17), sandstone, true);
        for (int x = -4; x <= 4; x++)
        for (int z = -4; z <= 4; z++)
        {
            Color tile = (x + z) % 2 == 0 ? new Color32(190, 171, 151, 255) : new Color32(202, 183, 164, 255);
            Part(transform, PrimitiveType.Cube, new Vector3(x * 1.78f, -0.016f, z * 1.78f), new Vector3(1.76f, 0.03f, 1.76f), tile);
        }
        Part(transform, PrimitiveType.Cube, new Vector3(0, 1.1f, 8.25f), new Vector3(17, 2.2f, 0.5f), sandstone, true);
        Part(transform, PrimitiveType.Cube, new Vector3(0, 0.45f, -8.25f), new Vector3(17, 0.9f, 0.5f), sandstone, true);
        foreach (int side in new[] { -1, 1 })
        {
            Part(transform, PrimitiveType.Cube, new Vector3(side * 8.25f, 0.6f, 0), new Vector3(0.5f, 1.2f, 17), sandstone, true);
            Part(transform, PrimitiveType.Cube, new Vector3(side * 4f, 0.23f, -2.55f), new Vector3(2.6f, 0.46f, 0.72f), new Color32(130, 82, 67, 255), true);
            foreach (float z in new[] { -5.9f, 0, 5.9f })
                MakePlanter(new Vector3(side * 6.4f, 0, z));
        }
        foreach (float x in new[] { -6.7f, -4f, -1.35f, 1.35f, 4f, 6.7f })
            Part(transform, PrimitiveType.Cube, new Vector3(x, 1.52f, 7.8f), new Vector3(0.28f, 3.04f, 0.34f), new Color32(242, 204, 170, 255));
        Part(transform, PrimitiveType.Cube, new Vector3(0, 3.06f, 7.81f), new Vector3(14.3f, 0.23f, 0.44f), new Color32(242, 204, 170, 255));
        Part(transform, PrimitiveType.Cylinder, new Vector3(0, 0.012f, 0.95f), new Vector3(4.9f, 0.013f, 4.9f), new Color32(140, 81, 87, 255));
        Part(transform, PrimitiveType.Cylinder, new Vector3(0, 0.023f, 0.95f), new Vector3(4.48f, 0.006f, 4.48f), new Color32(189, 114, 119, 255));
    }

    private void MakePlanter(Vector3 at)
    {
        Part(transform, PrimitiveType.Cube, at + Vector3.up * 0.31f, new Vector3(1.5f, 0.62f, 1.45f), new Color32(173, 105, 85, 255), true);
        Part(transform, PrimitiveType.Cube, at + Vector3.up * 0.64f, new Vector3(1.59f, 0.12f, 1.54f), sandstone);
        Part(transform, PrimitiveType.Cylinder, at + Vector3.up * 1.07f, new Vector3(0.26f, 0.50f, 0.26f), new Color32(120, 83, 75, 255));
        Part(transform, PrimitiveType.Sphere, at + new Vector3(-0.30f, 1.80f, 0), new Vector3(1.35f, 1.19f, 1.32f), new Color32(100, 139, 106, 255));
        Part(transform, PrimitiveType.Sphere, at + new Vector3(0.35f, 1.81f, 0.15f), new Vector3(1.26f, 1.15f, 1.2f), new Color32(124, 156, 110, 255));
        Part(transform, PrimitiveType.Sphere, at + new Vector3(0, 2.29f, -0.2f), new Vector3(1.40f, 1.36f, 1.35f), new Color32(148, 171, 116, 255));
    }

    private static Transform MakeCharacter(Transform parent, bool dancer)
    {
        Color skin = dancer ? new Color32(217, 153, 114, 255) : new Color32(186, 128, 93, 255);
        Color shirt = dancer ? new Color32(243, 139, 135, 255) : new Color32(39, 107, 115, 255);
        Color pants = dancer ? new Color32(81, 57, 85, 255) : new Color32(50, 60, 80, 255);
        Color hair = new Color32(56, 42, 53, 255);
        var actor = Joint(parent, "Character", Vector3.zero);
        var torso = Joint(actor, "Torso", Vector3.up * 0.79f);
        Part(torso, PrimitiveType.Sphere, Vector3.up * 0.24f, new Vector3(0.59f, 0.63f, 0.32f), shirt);
        Part(torso, PrimitiveType.Sphere, Vector3.up * 0.04f, new Vector3(0.48f, 0.24f, 0.29f), pants);
        Part(torso, PrimitiveType.Sphere, Vector3.up * 0.56f, new Vector3(0.19f, 0.23f, 0.19f), skin);
        var head = Joint(torso, "Head", Vector3.up * 0.73f);
        Part(head, PrimitiveType.Sphere, Vector3.zero, new Vector3(0.42f, 0.45f, 0.39f), skin);
        Part(head, PrimitiveType.Sphere, new Vector3(0, 0.107f, -0.034f), new Vector3(0.44f, 0.31f, 0.39f), hair);
        if (dancer)
        {
            Part(head, PrimitiveType.Sphere, new Vector3(0.045f, -0.045f, -0.14f), new Vector3(0.41f, 0.49f, 0.24f), hair);
            Part(head, PrimitiveType.Sphere, new Vector3(0.155f, 0.22f, -0.085f), new Vector3(0.24f, 0.25f, 0.27f), hair);
        }
        foreach (int side in new[] { -1, 1 })
        {
            string suffix = side < 0 ? "L" : "R";
            Part(head, PrimitiveType.Sphere, new Vector3(side * 0.077f, -0.012f, 0.181f), new Vector3(0.033f, 0.041f, 0.025f), hair);
            var arm = Joint(torso, "Arm" + suffix, new Vector3(side * 0.28f, 0.4f, 0));
            Part(arm, PrimitiveType.Sphere, Vector3.down * 0.123f, new Vector3(0.17f, 0.34f, 0.18f), shirt);
            var elbow = Joint(arm, "Elbow", Vector3.down * 0.255f);
            Part(elbow, PrimitiveType.Sphere, Vector3.down * 0.118f, new Vector3(0.13f, 0.29f, 0.14f), skin);
            var leg = Joint(torso, "Leg" + suffix, new Vector3(side * 0.14f, 0, 0));
            Part(leg, PrimitiveType.Sphere, Vector3.down * 0.17f, new Vector3(0.25f, 0.42f, 0.25f), pants);
            var knee = Joint(leg, "Knee", Vector3.down * 0.34f);
            Part(knee, PrimitiveType.Sphere, Vector3.down * 0.165f, new Vector3(0.20f, 0.39f, 0.20f), pants);
            Part(knee, PrimitiveType.Sphere, new Vector3(0, -0.37f, 0.065f), new Vector3(0.22f, 0.17f, 0.35f), new Color32(255, 244, 221, 255));
        }
        var animation = actor.gameObject.AddComponent<Animation>();
        animation.playAutomatically = false;
        animation.AddClip(MakeClip("Idle", 2.4f), "Idle");
        animation.AddClip(MakeClip("Walk", 0.64f), "Walk");
        if (dancer)
            animation.AddClip(LoadDance(), "Dance");
        return actor;
    }

    private static AnimationClip MakeClip(string name, float duration)
    {
        var clip = new AnimationClip { name = name, legacy = true, wrapMode = WrapMode.Loop };
        AddCurve(clip, "Torso", "localPosition.y", duration, p => 0.79f + Mathf.Cos(2 * p) * (name == "Idle" ? 0.008f : 0.028f));
        AddCurve(clip, "Torso", "localEulerAngles.y", duration, p => Mathf.Sin(p) * 4);
        AddCurve(clip, "Torso", "localPosition.x", duration, p => 0);
        foreach (int side in new[] { -1, 1 })
        {
            string suffix = side < 0 ? "L" : "R";
            string arm = "Torso/Arm" + suffix;
            string leg = "Torso/Leg" + suffix;
            AddCurve(clip, arm, "localEulerAngles.z", duration, p => side * 8);
            AddCurve(clip, arm, "localEulerAngles.x", duration, p => name == "Walk" ? side * Mathf.Sin(p) * 31 : 0);
            AddCurve(clip, arm + "/Elbow", "localEulerAngles.x", duration, p => 8);
            AddCurve(clip, leg, "localEulerAngles.x", duration, p => -side * Mathf.Sin(p) * (name == "Walk" ? 34 : 0));
            AddCurve(clip, leg + "/Knee", "localEulerAngles.x", duration, p => name == "Idle" ? 0 : Mathf.Max(0, side * Mathf.Sin(p)) * 36);
        }
        return clip;
    }

#pragma warning disable 0649 // Fields are populated by JsonUtility.
    [System.Serializable]
    private sealed class BakedClip
    {
        public float duration;
        public BakedTrack[] tracks;
    }

    [System.Serializable]
    private sealed class BakedTrack
    {
        public string joint;
        public string property;
        public float[] x;
        public float[] y;
        public float[] z;
    }
#pragma warning restore 0649

    private static AnimationClip LoadDance()
    {
        var source = Resources.Load<TextAsset>("Dance");
        var definition = JsonUtility.FromJson<BakedClip>(source.text);
        var clip = new AnimationClip { name = "Dance", legacy = true, wrapMode = WrapMode.Loop };
        foreach (BakedTrack track in definition.tracks)
        {
            bool rotation = track.property == "rotation";
            string property = rotation ? "localEulerAngles." : "localPosition.";
            // Convert the source rig's -Z forward convention to Unity's +Z forward.
            AddSamples(clip, track.joint, property + "x", definition.duration, track.x, rotation ? -1 : 1);
            AddSamples(clip, track.joint, property + "y", definition.duration, track.y, rotation ? -1 : 1);
            AddSamples(clip, track.joint, property + "z", definition.duration, track.z, rotation ? 1 : -1);
        }
        return clip;
    }

    private static void AddSamples(AnimationClip clip, string path, string property, float duration, float[] samples, float sign)
    {
        var curve = new AnimationCurve();
        for (int i = 0; i < samples.Length; i++)
            curve.AddKey(duration * i / (samples.Length - 1), samples[i] * sign);
        clip.SetCurve(path, typeof(Transform), property, curve);
    }

    private static void AddCurve(AnimationClip clip, string path, string property, float duration, System.Func<float, float> value)
    {
        var curve = new AnimationCurve();
        for (int i = 0; i <= 32; i++)
        {
            float fraction = i / 32f;
            curve.AddKey(fraction * duration, value(fraction * 2 * Mathf.PI));
        }
        clip.SetCurve(path, typeof(Transform), property, curve);
    }

    private static Transform Joint(Transform parent, string name, Vector3 position)
    {
        var joint = new GameObject(name).transform;
        joint.SetParent(parent, false);
        joint.localPosition = position;
        return joint;
    }

    private static void Part(Transform parent, PrimitiveType type, Vector3 position, Vector3 size, Color color, bool solid = false)
    {
        var part = GameObject.CreatePrimitive(type);
        part.transform.SetParent(parent, false);
        part.transform.localPosition = position;
        part.transform.localScale = size;
        if (!solid)
            part.GetComponent<Collider>().enabled = false;
        var properties = new MaterialPropertyBlock();
        properties.SetColor("_Color", color);
        part.GetComponent<Renderer>().SetPropertyBlock(properties);
    }
}
