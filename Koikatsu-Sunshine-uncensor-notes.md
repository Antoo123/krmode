# Koikatsu Sunshine (KKS) — uncensor и механика «соединения» гениталий с телом

Дата исследования: 2026-11-22.
Источник данных: открытые исходники на GitHub (все ссылки — рабочие репозитории).

---

## 1. Важное вводное: у BetterRepack нет «исходного кода»

**BetterRepack** (автор ScrewThisNoise) — это репак: готовая папка с игрой + уже установленные плагины и контент-моды.
Исходного кода у самого репака нет — это просто архив. Весь код живёт в открытых репозиториях на GitHub.

Ключевые источники:

- HF Patch для KKS (инсталлятор всего набора): https://github.com/ManlyMarco/KKS-HF_Patch
  - Полный список ~200 плагинов с указанием репозитория каждого: `Plugin Readme.md`
    https://github.com/ManlyMarco/KKS-HF_Patch/blob/master/Plugin%20Readme.md
- Организация-«зонтик» IllusionMods: https://github.com/IllusionMods
  - IllusionModdingAPI (KKAPI/KKSAPI): https://github.com/IllusionMods/IllusionModdingAPI
  - IllusionFixes: https://github.com/IllusionMods/IllusionFixes
  - KKManager: https://github.com/IllusionMods/KKManager
  - KK_Plugins: https://github.com/IllusionMods/KK_Plugins
- Фреймворк-загрузчик плагинов BepInEx: https://github.com/BepInEx/BepInEx
- Каталог модов (с фильтром по игре): https://charamods.com/en
- Вики Koikatsu Sunshine (тех. помощь): https://wiki.anime-sharing.com/hgames/index.php?title=Koikatsu_Sunshine

---

## 2. Карта установки KKS (где что лежит)

```
KoikatsuSunshine/
├── winhttp.dll            ← загрузчик BepInEx (удалишь — отключатся все моды)
├── BepInEx/
│   ├── plugins/           ← плагины (.dll) — весь мод-код
│   ├── patchers/          ← патчеры
│   ├── config/            ← настройки плагинов
│   └── Translation/       ← переводы (XUnity.AutoTranslator)
├── mods/                  ← контент-моды Sideloader (.zipmod — одежда, карты, uncensor-тела)
├── UserData/
│   ├── chara/female/      ← карточки персонажей
│   ├── chara/male/
│   ├── coordinate/        ← карточки нарядов
│   ├── Studio/scene/      ← сцены Studio
│   └── save/              ← сохранения
└── KKManager/             ← менеджер модов (KKManager.exe)
```

---

## 3. Uncensor: где лежит код

Всё в одном репозитории `IllusionMods/KK_Plugins`, папка `src/UncensorSelector.Core/`.

| Файл | Что внутри |
|---|---|
| `Core.UncensorSelector.cs` | Инициализация плагина + списки имён мешей (`BodyNames`, `PenisParts`, `BallsParts`) |
| `Core.UncensorSelector.Controller.cs` | Главная логика — подмена мешей тела/члена/яиц |
| `Core.UncensorSelector.Data.cs` | Классы `BodyData`/`PenisData`/`BallsData` + дефолтные пути к ассетам |
| `Core.UncensorSelector.Hooks.cs` | Harmony-перехваты + демозайка |
| `Guides/UncensorSelector Guide/uncensor_manifest_template.xml` | Шаблон `manifest.xml` — видна вся структура тел |
| `mods/KKS_UncensorSelector Base.zipmod` | Сами 3D-тела для Sunshine (базовый набор) |

GitHub-ссылки на файлы (ветка master):
https://github.com/IllusionMods/KK_Plugins/blob/master/src/UncensorSelector.Core/Core.UncensorSelector.cs
https://github.com/IllusionMods/KK_Plugins/blob/master/src/UncensorSelector.Core/Core.UncensorSelector.Controller.cs
https://github.com/IllusionMods/KK_Plugins/blob/master/src/UncensorSelector.Core/Core.UncensorSelector.Data.cs
https://github.com/IllusionMods/KK_Plugins/blob/master/src/UncensorSelector.Core/Core.UncensorSelector.Hooks.cs
https://github.com/IllusionMods/KK_Plugins/blob/master/Guides/UncensorSelector%20Guide/uncensor_manifest_template.xml
https://github.com/IllusionMods/KK_Plugins/blob/master/mods/KKS_UncensorSelector%20Base.zipmod

Дополнительно сами тела-паки для Sideloader лежат на:
https://sideload.betterrepack.com/download/KKEC/Sideloader%20Modpack%20-%20KK_UncensorSelector/

---

## 4. Механизм работы uncensor (по функциям)

Ключевой факт: **гениталии — это не отдельный объект, «приклеенный» к телу.**
Это SkinnedMeshRenderer'ы, которые уже есть у персонажа; плагин подменяет на них меш и материалы.

Путь вызова (в `Controller.cs`):

1. `ReloadCharacterUncensor()` — точка входа (корутина). Ждёт появления `ChaControl.objBody`, затем вызывает три функции ниже.
2. `ReloadCharacterBody()` — грузит из бандла `chara/oo_base.unity3d` ассет `p_cf_body_00` (жен.) / `p_cm_body_00` (муж.), находит меш по именам из `BodyNames` и копирует геометрию.
3. `ReloadCharacterPenis()` — подменяет меши по списку `PenisParts`; выставляет `fileStatus.visibleSonAlways`.
4. `ReloadCharacterBalls()` — то же для `BallsParts`.
5. `UpdateMeshRenderer(src, dst)` — `dst.sharedMesh = src.sharedMesh` + копирование материалов.
6. **`TransferBones(src, dst)`** — ответ на вопрос про «соединение»:

```csharp
foreach (Transform t in src.bones)
    newBones.Add(Array.Find(dst.bones, c => c != null && t != null && c.name == t.name));
dst.bones = newBones.ToArray();
```

Меш гениталий **ригуется к скелету персонажа по именам костей**: у нового меша берётся список его костей (`src.bones`), и каждая сопоставляется с одноимённой костью живого скелета (`dst.bones`).
Поэтому вульва/член деформируются вместе с телом (одни и те же кости таза/бёдер) и H-анимация двигает их автоматически — отдельной «стыковки» в коде нет.

---

## 5. Точные имена мешей

Из `Core.UncensorSelector.cs`:

```csharp
BodyNames  = { "o_body_a", "o_body_cf", "o_body_cm" }   // сам меш тела
BodyParts  = { "o_dankon", "o_dan_f", "o_gomu", "o_mnpa", "o_mnpb", "o_shadowcaster", "cm_o_dan00", "cm_o_dan_f" }
PenisParts = { "o_dankon", "o_gomu", "cm_o_dan00" }       // член + презерватив
BallsParts = { "o_dan_f", "cm_o_dan_f" }                  // яйца
```

| Имя объекта | Что это |
|---|---|
| `o_dankon` | пенис (данкон = 男根) |
| `o_gomu` | презерватив (гому = ゴム) |
| `o_dan_f` | яички |
| `o_mnpa` / `o_mnpb` | соски (mune = грудь, nipple) |
| `o_shadowcaster` | объект-тень |
| `o_body_cf` / `o_body_cm` | тело: cf = female, cm = male |

Дефолтные ассеты/материалы (из `Data.cs`, класс `Defaults`):

- бандл тела: `chara/oo_base.unity3d`, ассет `p_cf_body_00` / `p_cm_body_00` (+ суффикс `_low` для low-poly)
- бандл материалов: `chara/mm_base.unity3d`
- материалы тела: `cf_m_body` / `cm_m_body`, `cf_m_body_create`
- текстура тела: `cf_body_00_t`
- цветовая маска: `cf_body_00_mc` / `cm_body_00_mc`
- карта нормалей: `p_cf_body_00_Nml`

---

## 6. Демозайка

Одна строка в `Hooks.cs`:

```csharp
[HarmonyPrefix, HarmonyPatch(typeof(ChaControl), nameof(ChaControl.LateUpdateForce))]
private static void LateUpdateForce(ChaControl __instance) => __instance.hideMoz = true;
```

Флаг `hideMoz` (hide mosaic) у `ChaControl` каждый кадр ставится в `true` — это отключает мозаику.

Подмена текстур/материалов делается транспилерами, которые патчат строковые литералы внутри
`ChaControl.CreateBodyTexture` (загрузка `oo_base.unity3d`, `cf_body_00_t`, масок) и
`InitBaseCustomTextureBody` (загрузка `mm_base.unity3d`, `cf_m_body`, `cm_m_body`, `cf_m_body_create`).

Отдельный хак — `LoadAsyncTranspiler` (в `Hooks.cs`), подменяющий `p_cm_body_00_low`.
Причина: у женского тела больше костей, чем у мужского, поэтому мужское тело грузится как
женское low-ассет, чтобы подмена «мужчина → женское тело» не ломалась.

---

## 7. Пенетрация (совпадение члена с телом в H-сцене)

Это НЕ uncensor, а:

1. анимация (положение тазовых костей), к которым через `TransferBones` привязан меш члена;
2. отдельный плагин **KKS Better Penetration** (Animal42069):
   - добавляет dynamic bones + коллайдеры к uncensor-телам,
   - динамически двигает член и меняет его длину/толщину.
   - Исходники закрыты (Patreon); в списке плагинов BetterRepack указан как `KKS Better Penetration v5.1`.
   - Есть PDF-мануал «Better Penetration Studio Instructions» (f95zone).

---

## 8. Структура uncensor-пака (.zipmod)

Файл-пак тела (zipmod) содержит:
- `manifest.xml` — описание (GUID, имя, пол, пути к бандлам/ассетам, colorMatch);
- `.unity3d` asset-бандлы с мешами.

Из шаблона манифеста ключевые теги:
- `<body>` → `<oo_base>` (тело), `<mm_base>` (материал)
- `<penis>` → меши `o_dankon` + `o_gomu`
- `<balls>` → меш `o_dan_f`
- `<migration>` — сопоставление старых GUID со структурой body/penis/balls

Полный текст шаблона: см. `uncensor_manifest_template.xml` выше.

---

## 9. Полезные контакты/ресурсы

- Discord Koikatsu (основной канал помощи `#help`): https://discord.gg/zS5vJYS
- Мануал по HF Patch (ManlyMarco): https://gist.github.com/ManlyMarco/31b78470b8e190686c7ed9686c237e3f
- Download BetterRepack: https://dl.betterrepack.com/