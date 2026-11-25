# Koikatsu Sunshine — BetterRepack R13
## Полный отчёт: система анимаций, H-сцены, взаимодействие персонажей, моды и гайды

> Дата составления: 2026-11-23. Все факты проверены через первоисточники (GitHub raw/API, вики);
> непроверенные пункты явно помечены «НЕПРОВЕРЕНО».

---

# ЧАСТЬ 1. BetterRepack R13 — что это и где живёт

**BetterRepack** — неофициальный «всё-в-одном» модпак для Koikatsu Sunshine (и других игр Illusion), собираемый сообществом [IllusionMods](https://github.com/IllusionMods) (ManlyMarco и др.) на базе **Sideloader zipmod-архивов**.

| Ресурс | Ссылка |
|---|---|
| Официальный сайт | https://www.betterrepack.com/ |
| Файлы для скачивания | https://sideload.betterrepack.com/ |
| Patreon | https://www.patreon.com/BetterRepack |
| SubscribeStar | https://subscribestar.adult/betterrepack |
| Полный список плагинов (структура HF Patch = BetterRepack) | https://github.com/ManlyMarco/KK-HF_Patch/blob/master/Plugin%20Readme.md |

---

# ЧАСТЬ 2. Исходный код: как устроена анимационная система KKS

Все моды — **C# под BepInEx 5.x + HarmonyLib**, патчат Unity-сборки игры (`Assembly-CSharp`, Studio-библиотеки из [IllusionLibs](https://github.com/IllusionMods/IllusionLibs)). Сами анимации — Unity `AnimationClip`, проигрываемые `Animator`'ами через `AnimatorOverrideController`; в Studio ими управляет класс игры `Studio.AnimeControl`.

## 2.1. Ключевые репозитории (GitHub org IllusionMods, 43 репо)

| Репо | Лицензия | Что делает |
|---|---|---|
| [AnimationLoader](https://github.com/IllusionMods/AnimationLoader) | GPL-3.0 | Загрузка кастомных анимаций из Sideloader zipmod'ов. KKS — полноценная цель сборки (`src/AnimationLoader.KoikatsuSunshine/`) |
| [KK_Plugins](https://github.com/IllusionMods/KK_Plugins) | GPL-3.0 | AnimationOverdrive, AnimationController (устарел), FKIK, TimelineFlowControl, Colliders, Pushup, MaleJuice, HCharaAdjustment, PoseTools, Boop и др. — у каждого проекты `.{Core,KK,KKS,AI,HS2}` |
| [IllusionModdingAPI](https://github.com/IllusionMods/IllusionModdingAPI) | LGPL-3.0 | Моддинг-API: PHAPI / KKAPI / ECAPI / AIAPI / HS2API / **KKSAPI**; общий проект `Shared.CharaStudio` даёт StudioAPI-хуки для анимационных плагинов |
| [BepisPlugins](https://github.com/IllusionMods/BepisPlugins) | LGPL-3.0 | Sideloader — система zipmod'ов, на которой стоит AnimationLoader |
| [IllusionFixes](https://github.com/IllusionMods/IllusionFixes) | GPL-3.0 | Набор фиксов игры |
| [IllusionLibs](https://github.com/IllusionMods/IllusionLibs) | — | Референс-сборки игры, против которых собираются все плагины |
| [KoikatsuModdingTools](https://github.com/IllusionMods/KoikatsuModdingTools) | — | VS-шаблоны/инструменты для sideloader-модов |
| [ModBoneImplantor](https://github.com/IllusionMods/ModBoneImplantor) | MIT | Внедрение кастомных костей в одежду (для rigged/animated предметов) |
| [KKManager](https://github.com/IllusionMods/KKManager) | GPL-3.0 | Менеджер модов/карточек, качает анимационные zipmod'ы |
| [ZipStudio](https://github.com/IllusionMods/ZipStudio) / [Unity3DCompressor](https://github.com/IllusionMods/Unity3DCompressor) | C# | Редактирование zipmod / сжатие Unity-бандлов |

**Не существует в этом org:** `TimelineMod`, `Timeline`, `KKAPI` (правильное имя — IllusionModdingAPI) — все дают 404. Полный поиск по org на «animation» вернул только AnimationLoader, на «timeline» — ноль.

## 2.2. Внутренности AnimationLoader (главный «исходник по анимациям»)

Исходники (всё C# / BepInEx / Harmony):

- [Plugin.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/Plugin.cs) — входная точка
- [AnimationClipsCache.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/AnimationClipsCache.cs) — кэш AnimationClip'ов из zipmod'ов
- [AnimationsNames.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/AnimationsNames.cs) — таблицы имён встроенных анимаций
- [AnimatorOverrideController.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/AnimatorOverrideController.cs) — подмена клипов в аниматорах
- [Hooks.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/Hooks.cs), [Hooks.Studio.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/Hooks.Studio.cs), [Hooks.Animators.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/Hooks.Animators.cs), [Hooks.AnimationLists.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/Hooks.AnimationLists.cs) — Harmony-хуки в списки анимаций Studio
- [MotionIK.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/MotionIK.cs) + [MotionIKDataSerializable.cs](https://github.com/IllusionMods/AnimationLoader/blob/master/src/AnimationLoader.Core/MotionIKDataSerializable.cs) (~50 КБ) — сериализация IK-движения (та же система MotionIK, что в H-сценах)
- `LoadXML.cs` / `LoadXML.ProcessArray.cs` / `LoadXML.VersionChecks.cs` — разбор манифеста
- `src/AnimationLoader.KoikatsuSunshine/` и `src/AnimationLoader.Koikatu/` — игровые проекты (общий Core + csproj)

Требования: BepInEx, IllusionModdingAPI ≥ 1.39, BepisPlugins ≥ 20.0. «Thanks to Essu for the main bulk of the code».

Формат zipmod-манифеста: [template.xml](https://github.com/IllusionMods/AnimationLoader/blob/master/template.xml) — полный шаблон + дословные таблицы **всех ванильных ID позиций KK и KKS** (houshi 0–65 KKS, sonyu 0–52 KKS). Документация манифеста: [wiki manifest.xml](https://github.com/IllusionMods/AnimationLoader/wiki/manifest.xml).

## 2.3. AnimationOverdrive — пример исходника

- [Core.AnimationOverdrive.cs](https://github.com/IllusionMods/KK_Plugins/blob/master/src/AnimationOverdrive.Core/Core.AnimationOverdrive.cs): плагин `com.deathweasel.bepinex.animationoverdrive` v1.1, только Studio, `AnimationSpeedMax = 1000f`
- [Core.AnimationOverdrive.Hooks.cs](https://github.com/IllusionMods/KK_Plugins/blob/master/src/AnimationOverdrive.Core/Core.AnimationOverdrive.Hooks.cs): `HarmonyTranspiler` на `Studio.AnimeControl.OnEndEditSpeed` заменяет хардкод-лимит скорости **3 → 1000**, `HarmonyPrefix` расширяет `maxValue` слайдера. Подтверждает класс игры: **`Studio.AnimeControl`**.

---

# ЧАСТЬ 3. Анимационные моды в составе репака

| Мод | Назначение | Источник |
|---|---|---|
| **Timeline** (joan6694, Ctrl+T) | Главный покадровый редактор анимаций в Studio. Закрытый код, распространяется через [Patreon joan6694](https://www.patreon.com/joan6694/posts/hs-kk-timeline-1-37188531) / Koikatsu Discord; в GitHub-органе IllusionMods его нет (404) | HF Patch Readme: «Advanced animation editor for Studio (Ctrl+T, read the Help)» — https://github.com/ManlyMarco/KK-HF_Patch/blob/master/Plugin%20Readme.md |
| **AnimationLoader** v1.1.3.4 | Кастомные анимации из zipmod'ов | https://github.com/IllusionMods/AnimationLoader/releases/tag/v1.1.3.4 |
| **AnimationOverdrive** | Скорость анимаций выше лимита 3 (до 1000) | https://github.com/IllusionMods/KK_Plugins |
| **FKIK** (DeathWeasel1337) | FK и IK одновременно | там же |
| **VMDPlayPlugin** (Ctrl+Shift+V) | Анимации MMD/VMD в Studio | HF Patch Readme |
| **TimelineFlowControl** | Логика/ограниченные циклы для Timeline | KK_Plugins README |
| **AnimationController** | ⚠️ устарел: «NodeConstraints does what this plugin does but better» | KK_Plugins README |
| **Katarsys / KPlug Animation Bundles** | **KPlug Animations v3.3** — ~1.2 ГБ (1 195 726 322 байт) кастомных H-анимаций; ставится в `mods/MyMods/Animation/Katarsys` | https://sideload.betterrepack.com/download/KKEC/Sideloader%20Modpack%20-%20Animations/Katarsys/ |
| **KPlug.Animations v1.5.3** | Небольшой конфиг-пакет | там же |

Сторонние плагины (другие авторы, экосистема вокруг Timeline):

| Плагин | Что делает | Ссылка |
|---|---|---|
| **ShalltyUtils** (ShalltyB) | «bake animation» — конвертация встроенных анимаций в keyframes Timeline | https://github.com/ShalltyB/ShalltyUtils |
| **GIN_LifeHacks** (GoriGinsan) | Animation workflow helpers: Timeline + KKPE Advanced mode | https://github.com/GoriGinsan/GIN_LifeHacks |
| **GIN_IKTHIS** (GoriGinsan) | IK authoring и FK baking для Timeline | https://github.com/GoriGinsan/GIN_IKTHIS |
| **ACE4Timeline** (Njaecha) | AnimationCurveEditor для Timeline | https://github.com/Njaecha/ACE4Timeline |
| **TimelineVMDSync** (Njaecha) | Одновременное управление Timeline и VMDPlay (+MMDD с 3.0.0) | https://github.com/Njaecha/TimelineVMDSync |
| **fast-timeline** (OQ-J) | Производительность воспроизведения/UI Timeline, MIT | https://github.com/OQ-J/fast-timeline |
| **CloTimelineBar** (Clo15) | Транспорт-бар play/pause/scrub для Timeline | https://github.com/Clo15/CloTimelineBar |
| **KKTimelineDetector** (GameProgram777) | Python-детектор данных Timeline в сценах KK/KKS | https://github.com/GameProgram777/KKTimelineDetector |
| **KKS_VR_TimelineCameraSync** (YukyoMoe) | Синхронизация камеры Timeline в KKS Studio VR | https://github.com/YukyoMoe/KKS_VR_TimelineCameraSync |
| **KK-Studio-Mods** (dumbiart666-png) | Автоматизация Timeline, анимация мешей одежды, выражения, MIT | https://github.com/dumbiart666-png/KK-Studio-Mods |
| **AdvIKPlugin** (OrangeSpork) | Управление плечами в IK | https://github.com/OrangeSpork/AdvIKPlugin |
| **FKHeightAdjustUI** (OrangeSpork) | Компенсация высоты для FK-поз/анимаций | https://github.com/OrangeSpork/FKHeightAdjustUI |
| **NodesConstraints** (joan6694) | Кастомные анимации через привязку узлов (замена AnimationController) | Patreon joan6694 / KK Discord |
| **Auto Keyframe**, **The Bird of Hermes** (Rinu Nalo) | Автообновление keyframes; аудио+waveform для Timeline | KK Discord |
| **VideoExport** (joan6694) | Запись видео/gif из Studio (Ctrl+E) | Patreon joan6694 |
| **HS2-Sandbox** (SuitIThub) | Браузер всех анимаций с превью (Anim/Pose Browser) | https://github.com/SuitIThub/HS2-Sandbox |

⚠️ **Не существуют / не подтверждены:** «KK_ADBrowser», «HSAnimationEngine», «KsoMoveMotion/MoveMotion» (есть StudioObjectMoveHotkeys), «KK_CursedArmor», «DynamicBoneReplacements», «HScenePosing», «KK_HandsBSTweak», «JuiceBlending», «HAnimationLoader» как отдельный плагин, «KKS_StudioObjectAutoHide» (реально — InvisibleBody).

---

# ЧАСТЬ 4. H-сцены: как реализовано взаимодействие двух персонажей

## 4.1. Ядро (C#, Assembly-CSharp) — подтверждено исходниками

- **`HSceneProc`** (namespace `H`) — центральный класс H-сцены. Поля: `List<MotionIK> lstMotionIK`, `List<ChaControl> lstFemale`, `ChaControl male`, `HFlag flags`, вложенный `HSceneProc.AnimationListInfo` (`id` загружаемой анимации).
- **`HFlag.EMode`** — режимы: `aibu=0` (ласки/касания), `houshi=1` (обслуживание: рука/рот/грудь), `sonyu=2` (секс), `masturbation=3`, `peeping=4`, `lesbian=5`, `houshi3P=6`, `sonyu3P=7`, `3P-MMF=8/9`. MotionIK-логика активна в `sonyu`. (Дословное перечисление — в [template.xml](https://github.com/IllusionMods/AnimationLoader/blob/master/template.xml).)
- **`MotionIK`** — IK-движок игры: `new MotionIK(ChaControl)`, `SetPartners(List<MotionIK>)`, `Reset()`, `Calc("Idle")`, `Release()`, `LoadData(TextAsset)`, поле `data` (`MotionIKData`). По одному на персонажа; `SetPartners` связывает их в пару.

## 4.2. Данные IK (`MotionIKData`) — почему «всё попадает куда надо»

```
MotionIKData
└─ states[]                       — по одному на состояние анимации
   ├─ State
   │  ├─ parts[4]                 — leftHand, rightHand, leftFoot, rightFoot
   │  │  ├─ param2 (Target):  sex (чьё тело), target (имя кости-цели на партнёре),
   │  │  │                     weightPos, weightAng
   │  │  └─ param3 (Chain):   chein (имя цепочки костей), weight
   │  └─ frames[] → shapes[] → PosAng [small/large]: pos, ang (Vector3) — поправки
```

**Суть:** рука/нога не «угадывает» позицию — она IK-привязывается к **именнованной кости-цели на теле партнёра** (грудь/попа/бёдра — конкретные кости) с весом притяжения, а поверх идут **кадровые и шейповые поправки** (`frames/shapes`) под размер/форму тела. Отсюда отсутствие «кривизны»: попадание задаётся данными, а не позой клипа.

- Состояний у sonyu-анимаций — **24 или 48** («48 states animations»): `A_Idle`, `A_Insert`, `A_WLoop`, `A_SLoop`, `A_OLoop`, `A_M_IN_Start`, `A_M_OUT_Start`, `A_Pull`, `A_Drop` и др. — synced-клипы вставки/вынимания.
- Ванильные IK-данные — **TextAsset в `h/list/`** (`GlobalMethod.LoadAllFolderInOneFile<TextAsset>("h/list/", file)`); кастомные — JSON в `UserData/AnimationLoader/MotionIK/*.json`.

## 4.3. Синхронизация пары (объятия сзади и любые позиции)

- Каждая H-позиция = **пара AnimationController'ов**: female (`PathFemale`/`ControllerFemale`, напр. `khh_f_60`) + male (`PathMale`/`ControllerMale`, `khh_m_60`) из `.unity3d`-бандлов.
- Клипы пары проигрываются синхронно по состояниям; контакт рук/ног между телами сшивает MotionIK (`lstMotionIK` + `SetPartners`).
- Список позиции (ListInfo): `id`, `mode`, `nameAnimation`, `posture`, `numCtrl`, `kindHoushi`, `houshiLoopActionS`, `isFemaleInitiative`, `lstCategory`, `paramFemale.fileSiruPaste`.
- Категории мест (`lstCategory`): LieDown, Stand, SitChair, Stool, SofaBench, Wall, SchoolDesk, Pool + спец. ID (1004 pool, 1300 volleyball net, 1301 table tennis).
- `kindHoushi` (Hand/Mouth/Breasts) — какая часть обслуживается; `FileSiruPaste` (Tits/Pussy/Butt) — куда «кончить снаружи».

## 4.4. Грудь / попа / пизда: софт-физика и коллизии

| Механизм | Реализация | Подтверждение |
|---|---|---|
| Софт-физика груди/ягодиц | **DynamicBone** (Unity-ассет) | [DynamicBoneEditor](https://github.com/IllusionMods/KK_Plugins) в KK_Plugins |
| Коллизия рука↔грудь↔пол↔юбка | Сфер-коллайдеры на костях | [Colliders](https://github.com/IllusionMods/KK_Plugins): «Adds floor, breast, hand, and skirt colliders… toggled in Studio» |
| Деформация груди под руками/одеждой | **Pushup** | KK_Plugins |
| «Жидкость» в H-сценах | **MaleJuice** | KK_Plugins (`src/MaleJuice.Core`) |
| Проникновение | **BetterPenetration** — «dynamic uncensors with better animations» | [KKS Technical Help wiki](https://wiki.anime-sharing.com/hgames/index.php?title=Koikatsu_Sunshine/Technical_Help) |
| Ласки/пальцы (`aibu`) | Свои клипы + те же IK-цепи с `target`-костями | архитектура Parts (детали кода aibu — НЕПРОВЕРЕНО) |

## 4.5. Коррекция рассогласований

- **HCharaAdjustment** (KK_Plugins) — сдвиг героини в H-сцене хоткеями (в ванили точной подстройки нет).
- **HCharaAdjustmentX** ([IDontHaveIdea](https://github.com/IDontHaveIdea/HCharaAdjustmentX), активен, GPL-3.0) — расширенное «Reposition characters during H scene».
- **KK_HSceneOptions** ([IDontHaveIdea](https://github.com/IDontHaveIdea/KK_HSceneOptions), ветка KKS-port) — твики H-сцены.
- Для кастомных анимаций в манифесте: **`PositionHeroine` / `PositionPlayer`** (x/y/z, раздельная подгонка персонажей) и **`DonorPoseId` / `NeckDonorId` / `MotionIKDonor`** — MotionIK-данные и поза «заимствуются» у ванильной позиции-донора. **Это главный трюк выравнивания кастомных H-анимаций.**
- **ExpTaii** (только KKS): None / 50% / 100% — разблокировка поз по опыту героини.
- **FreeHStudioSceneLoader** (KK_Plugins, эксперим.) — сцены Studio как H-карты.

## 4.6. H-режим vs Studio (два персонажа)

- **H-режим:** пара анимируется парными контроллерами, позиции связаны донорами и MotionIK — «само попадает».
- **Studio:** персонажи — отдельные объекты; позирование FK/IK (FKIK), пара подгоняется вручную, анимация через Timeline/NodeConstraints; позы сохраняются карточками .png (PoseTools/PoseQuickLoad).
- В обратную сторону: FreeHStudioSceneLoader.

## 4.7. Workflow кастомной H-анимации (подтверждено форматом)

1. Экспорт пары клипов male/female в `.unity3d` (пути вида `anim_imports/kplug/female/*.unity3d`).
2. Манифест zipmod: `ControllerFemale/Male`, `Mode`, `kindHoushi`, `categories`, `PositionHeroine/Player`, доноры (`DonorPoseId`, `NeckDonorId` — MotionIK у ванильной позиции), `ExpTaii`, секции `<Koikatu>`/`<KoikatsuSunshine>`, `GameSpecificOverrides`.
3. Zipmod → в `mods/` → AnimationLoader подхватывает. Справочник ID — [template.xml](https://github.com/IllusionMods/AnimationLoader/blob/master/template.xml), формат — [wiki manifest.xml](https://github.com/IllusionMods/AnimationLoader/wiki/manifest.xml).

---

# ЧАСТЬ 5. Гайды

## Анимирование (Timeline, FK/IK)
- [KK-HF_Patch Plugin Readme](https://github.com/ManlyMarco/KK-HF_Patch/blob/master/Plugin%20Readme.md) — полный список плагинов с описаниями
- [Timeline changelog/releases — joan6694 Patreon](https://www.patreon.com/joan6694/posts/hs-kk-timeline-1-37188531)
- [Timeline на charamods.com](https://charamods.com/en/mods/timeline) · [TimelineFlowControl](https://charamods.com/en/mods/timeline-flow-control)
- [Koikatsu CharaStudio Quickstart Guide (DeviantArt)](https://www.deviantart.com/renaikatsudou/art/Koikatsu-CharaStudio-Quickstart-Guide-1310243203)
- [The Complete Brainlet's Guide to CharaStudio (PDF)](https://files.catbox.moe/smwwnx.pdf) (зеркало Scribd: https://www.scribd.com/document/693654385/The-Complete-Brainlet-s-Guide-to-CharaStudio)
- [In Piston We Trust — pistons/node constraints (Scribd)](https://www.scribd.com/document/706155902/In-Piston-We-Trust)
- [Bake встроенной анимации в Timeline через ShalltyUtils (f95zone thread)](https://f95zone.to/threads/how-to-convert-built-in-animation-to-animation-timeline-in-koikatsu-studio.313890/)
- [How to make sex animations in CharaStudio/Koikatu (f95zone)](https://f95zone.to/threads/how-to-make-sex-animations-in-charastudio-koikatu.54682/)
- Видео: [How To Animate in Koikatsu! Using the Timeline Mod](https://www.youtube.com/watch?v=JOqf2wFWegs) · [Timeline guide, animating in koikatsu](https://www.youtube.com/watch?v=LGq2g5kP7wg) · [CharaStudio Timeline (китайский, bilibili)](https://www.bilibili.com/video/av623006203/)

## MMD / VMD
- [MMDD Tutorial (koikatsu-info.net, японский)](https://koikatsu-info.net/studio/mmdd_tutorial/)
- [VNGE and MMDD install guide (Countd360, Patreon)](https://www.patreon.com/c360plugins/posts/vnge-and-mmdd-94912633)
- [CharaStudio MMD-обзор (zhouxuebin.club, китайский)](https://zhouxuebin.club/blog/posts/chara-studio-mmdd/7d1b48ba/)
- [TimelineVMDSync](https://github.com/Njaecha/TimelineVMDSync) — синхронное управление Timeline и VMDPlay/MMDD
- [Koikatsu to MMD: The Full Guide [EDIT FOR KKS] (DeviantArt)](https://www.deviantart.com/akemiwhy/art/Koikatsu-to-MMD-The-Full-Guide-EDIT-FOR-KKS-963432338)
- Видео: [Koikatsu: Importing MMD/VMD into CharaStudio](https://www.youtube.com/watch?v=UntvbQ5pHtg)

## Общий моддинг
- [Hgames Wiki — Koikatu/Modding](https://wiki.anime-sharing.com/hgames/index.php?title=Koikatu/Modding)
- [Koikatsu Sunshine: Technical Help](https://wiki.anime-sharing.com/hgames/index.php?title=Koikatsu_Sunshine/Technical_Help)
- [AnimationLoader wiki](https://github.com/IllusionMods/AnimationLoader/wiki/manifest.xml)
- Koikatsu Discord (#guides) — основной хаб (требует логина)

## Не удалось проверить
- `wiki.illusionmods.net` — сеть недоступна из сессии исследования.
- gitgoon.dev-зеркала wiki — защищены anti-bot (Anubis PoW); использованы GitHub-wiki.
- Поиск f95zone требует логина (частично); kemono/Patreon-страницы частично недоступны.
- Имена IK-цепочек внутри бинарных `h/list/`, что индексируют `shapeNo`/`editNo`, детали кода `aibu`, структура `abdata` — НЕПРОВЕРЕНО (потребуется дамп бандлов через AssetRipper/SB3Utility).

---

# Резюме

Технически вся анимационная система BetterRepack R13 держится на трёх китах:
1. **Unity AnimationClip + AnimatorOverrideController + MotionIK** — механика игры; попадание рук обеспечено IK-привязкой к именованным костям партнёра + кадровыми/шейповыми поправками.
2. **AnimationLoader + Sideloader zipmod'ы** — доставка кастомных анимаций (~1.2 ГБ Katarsys в репаке), с донорскими MotionIK-данными от ванильных позиций.
3. **Timeline + его открытая экосистема** (ShalltyUtils, GIN_*, ACE4Timeline, fast-timeline и др.) — покадровое создание своих анимаций в Studio.