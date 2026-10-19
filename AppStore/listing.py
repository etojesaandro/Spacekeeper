#!/usr/bin/env python3
"""The App Store listing in every language, checked against Apple's limits.

  python3 -I AppStore/listing.py          # checks, and writes listing.json for copying into App Store Connect
"""
import json, pathlib, sys

LIMITS = {"name": 30, "subtitle": 30, "promotional": 170, "keywords": 100, "description": 4000}

L = {}

L["en-US"] = dict(
 name="Spacekeeper",
 subtitle="Free space, keep every photo",
 promotional="See which photos and videos take the most room, then move them to Yandex Disk, Google Drive or your computer. Checked before anything is deleted.",
 keywords="storage,free up space,photo backup,video,cleaner,google drive,yandex disk,cloud,compress,iphone",
 description="""Your iPhone is full, but every photo matters. Spacekeeper shows what takes the room and moves it somewhere safe, so you get the space back without losing a single memory.

SEE WHAT TAKES THE ROOM
• Every photo and video with its size, the biggest first
• Look by year or by month and see what each period weighs
• Filter photos, videos, or what is only in iCloud

MOVE IT SOMEWHERE SAFE
• Move, Copy or Delete only, one item or hundreds at once
• To Yandex Disk or Google Drive, in year and month folders, with the dates the photos were taken
• Uploads go on in the background when you leave the app
• Before anything is deleted, the copy in your cloud is checked against the original, and iOS asks you to confirm

BRING THEM BACK
• Browse what your cloud keeps and restore originals to Photos, Live Photos included

BACK UP TO A COMPUTER
• Over the cable to Windows, macOS or Linux, no internet needed
• The same year and month folders; running it again fetches only what is new

PRIVATE BY DESIGN
• No account, no tracking, no analytics
• Your photos go only to the cloud or computer you choose
• On Google Drive, Spacekeeper sees only the files it puts there itself
• Open source

Spacekeeper speaks English, Russian, Ukrainian, German, Spanish, French, Italian, Portuguese, Chinese and Japanese.""")

L["ru"] = dict(
 name="Spacekeeper",
 subtitle="Место есть, фото на месте",
 promotional="Узнайте, какие фото и видео занимают больше всего места, и перенесите их на Яндекс Диск, Google Диск или компьютер. С проверкой перед удалением.",
 keywords="память,освободить место,бэкап фото,видео,очистка,яндекс диск,google диск,облако,хранилище",
 description="""Память iPhone заполнена, но каждое фото важно. Spacekeeper показывает, что занимает место, и переносит это в надёжное хранилище — вы освобождаете место и не теряете ни одного воспоминания.

ЧТО ЗАНИМАЕТ МЕСТО
• Все фото и видео с размерами, самые большие — вверху
• По годам и месяцам, с весом каждого периода
• Фильтры: фото, видео, только в iCloud

ПЕРЕНОС В НАДЁЖНОЕ МЕСТО
• Переместить, скопировать или просто удалить — один объект или сотни сразу
• На Яндекс Диск или Google Диск, по папкам годов и месяцев, с датой съёмки
• Загрузка продолжается в фоне, даже если выйти из приложения
• Перед удалением копия в облаке сверяется с оригиналом, а iOS просит подтверждения

ВОЗВРАТ
• Просматривайте облако и возвращайте оригиналы в Фото, включая Live Photos

КОПИЯ НА КОМПЬЮТЕР
• По кабелю на Windows, macOS или Linux, без интернета
• Те же папки по годам и месяцам; повторный запуск забирает только новое

КОНФИДЕНЦИАЛЬНОСТЬ
• Без регистрации, без слежки и аналитики
• Фото попадают только в выбранное вами облако или на ваш компьютер
• На Google Диске Spacekeeper видит только свои файлы
• Открытый исходный код

Spacekeeper говорит на русском, украинском, английском, немецком, испанском, французском, итальянском, португальском, китайском и японском.""")

L["uk"] = dict(
 name="Spacekeeper",
 subtitle="Місце є, фото на місці",
 promotional="Дізнайтеся, які фото й відео займають найбільше місця, і перенесіть їх на Google Диск, Яндекс Диск або комп’ютер. З перевіркою перед видаленням.",
 keywords="пам'ять,звільнити місце,резервна копія,фото,відео,очищення,google диск,хмара,сховище",
 description="""Пам’ять iPhone заповнена, але кожне фото важливе. Spacekeeper показує, що займає місце, і переносить це в надійне сховище — ви звільняєте місце й не втрачаєте жодного спогаду.

• Усі фото й відео з розмірами, найбільші — вгорі; за роками й місяцями
• Перемістити, скопіювати або просто видалити — один об’єкт чи сотні одразу
• На Google Диск або Яндекс Диск, за теками років і місяців, з датою зйомки
• Вивантаження триває у фоні
• Перед видаленням копію звіряють з оригіналом, а iOS просить підтвердження
• Повертайте оригінали у Фотографії, зокрема Live Photos
• Копія на комп’ютер кабелем: Windows, macOS чи Linux, без інтернету
• Без реєстрації, стеження й аналітики; відкритий код""")

L["de-DE"] = dict(
 name="Spacekeeper",
 subtitle="Platz schaffen, Fotos behalten",
 promotional="Sieh, welche Fotos und Videos den meisten Platz belegen, und verschiebe sie zu Google Drive, Yandex Disk oder auf deinen Computer. Vor dem Löschen geprüft.",
 keywords="speicher,platz freigeben,foto backup,video,aufräumen,google drive,cloud,speicherplatz,iphone",
 description="""Dein iPhone ist voll, aber jedes Foto zählt. Spacekeeper zeigt, was den Platz belegt, und bringt es an einen sicheren Ort – so bekommst du Platz zurück, ohne eine einzige Erinnerung zu verlieren.

• Jedes Foto und Video mit seiner Größe, die größten zuerst; nach Jahr und Monat
• Verschieben, Kopieren oder nur Löschen – einzeln oder Hunderte auf einmal
• Zu Google Drive oder Yandex Disk, in Ordnern nach Jahr und Monat, mit Aufnahmedatum
• Uploads laufen im Hintergrund weiter
• Vor dem Löschen wird die Kopie mit dem Original verglichen, und iOS fragt nach
• Originale zurück in Fotos holen, auch Live Photos
• Backup per Kabel auf Windows, macOS oder Linux, ohne Internet
• Kein Konto, kein Tracking, keine Analyse; Open Source""")

L["es-ES"] = dict(
 name="Spacekeeper",
 subtitle="Libera espacio, guarda fotos",
 promotional="Descubre qué fotos y vídeos ocupan más y muévelos a Google Drive, Yandex Disk o tu ordenador. Se comprueban antes de eliminar nada.",
 keywords="almacenamiento,liberar espacio,copia de fotos,video,limpiar,google drive,nube,iphone",
 description="""Tu iPhone está lleno, pero cada foto importa. Spacekeeper muestra qué ocupa el espacio y lo lleva a un lugar seguro: recuperas espacio sin perder ningún recuerdo.

• Cada foto y vídeo con su tamaño, los más grandes primero; por año y mes
• Mover, Copiar o solo Eliminar: uno o cientos a la vez
• A Google Drive o Yandex Disk, en carpetas por año y mes, con la fecha de captura
• Las subidas siguen en segundo plano
• Antes de eliminar, la copia se compara con el original e iOS pide confirmación
• Recupera originales en Fotos, también Live Photos
• Copia por cable a Windows, macOS o Linux, sin internet
• Sin cuenta, sin rastreo, sin analíticas; código abierto""")

L["fr-FR"] = dict(
 name="Spacekeeper",
 subtitle="Libérez l’espace, gardez tout",
 promotional="Voyez quelles photos et vidéos prennent le plus de place et déplacez-les vers Google Drive, Yandex Disk ou votre ordinateur. Vérifié avant suppression.",
 keywords="stockage,libérer espace,sauvegarde photo,vidéo,nettoyage,google drive,cloud,iphone",
 description="""Votre iPhone est plein, mais chaque photo compte. Spacekeeper montre ce qui prend la place et le met à l’abri : vous récupérez de l’espace sans perdre un seul souvenir.

• Chaque photo et vidéo avec sa taille, les plus grosses d’abord ; par année et par mois
• Déplacer, Copier ou seulement Supprimer : un élément ou des centaines
• Vers Google Drive ou Yandex Disk, en dossiers par année et mois, avec la date de prise de vue
• Les envois continuent en arrière-plan
• Avant toute suppression, la copie est comparée à l’original et iOS demande confirmation
• Récupérez les originaux dans Photos, Live Photos compris
• Sauvegarde par câble vers Windows, macOS ou Linux, sans internet
• Sans compte, sans pistage, sans statistiques ; open source""")

L["it"] = dict(
 name="Spacekeeper",
 subtitle="Libera spazio, tieni ogni foto",
 promotional="Scopri quali foto e video occupano più spazio e spostali su Google Drive, Yandex Disk o sul computer. Controllati prima di eliminare.",
 keywords="memoria,liberare spazio,backup foto,video,pulizia,google drive,cloud,archivio,iphone",
 description="""Il tuo iPhone è pieno, ma ogni foto conta. Spacekeeper mostra cosa occupa spazio e lo mette al sicuro: recuperi spazio senza perdere un ricordo.

• Ogni foto e video con la sua dimensione, i più grandi prima; per anno e mese
• Sposta, Copia o solo Elimina: uno o centinaia alla volta
• Su Google Drive o Yandex Disk, in cartelle per anno e mese, con la data dello scatto
• I caricamenti continuano in background
• Prima di eliminare, la copia viene confrontata con l’originale e iOS chiede conferma
• Recupera gli originali in Foto, anche le Live Photo
• Backup via cavo su Windows, macOS o Linux, senza internet
• Nessun account, nessun tracciamento, nessuna analisi; open source""")

L["pt-BR"] = dict(
 name="Spacekeeper",
 subtitle="Libere espaço, guarde fotos",
 promotional="Veja quais fotos e vídeos ocupam mais espaço e mova-os para o Google Drive, Yandex Disk ou seu computador. Conferidos antes de apagar.",
 keywords="armazenamento,liberar espaço,backup de fotos,vídeo,limpeza,google drive,nuvem,iphone",
 description="""Seu iPhone está cheio, mas cada foto importa. O Spacekeeper mostra o que ocupa espaço e leva para um lugar seguro: você recupera espaço sem perder nenhuma lembrança.

• Cada foto e vídeo com seu tamanho, os maiores primeiro; por ano e mês
• Mover, Copiar ou só Apagar: um item ou centenas de uma vez
• Para o Google Drive ou Yandex Disk, em pastas por ano e mês, com a data da foto
• Os envios continuam em segundo plano
• Antes de apagar, a cópia é conferida com o original e o iOS pede confirmação
• Recupere originais no Fotos, inclusive Live Photos
• Backup pelo cabo para Windows, macOS ou Linux, sem internet
• Sem conta, sem rastreamento, sem análises; código aberto""")

L["zh-Hans"] = dict(
 name="Spacekeeper",
 subtitle="释放空间，保留每张照片",
 promotional="查看哪些照片和视频最占空间，并将它们移到 Google 云端硬盘、Yandex Disk 或电脑。删除前先核对。",
 keywords="存储,释放空间,照片备份,视频,清理,云端硬盘,云,iPhone",
 description="""iPhone 存储已满，但每张照片都很重要。Spacekeeper 显示最占空间的内容，并把它们移到安全的地方——释放空间，不丢失任何回忆。

• 每张照片和每个视频都标明大小，最大的排在最前；可按年或月查看
• 移动、复制或仅删除：一项或上百项
• 移到 Google 云端硬盘或 Yandex Disk，按年和月分文件夹，保留拍摄日期
• 上传在后台继续
• 删除前，云端副本会与原件核对，并由 iOS 请你确认
• 将原件恢复到“照片”，包括实况照片
• 通过数据线备份到 Windows、macOS 或 Linux，无需联网
• 无需账户，不追踪，不分析；开源""")

L["ja"] = dict(
 name="Spacekeeper",
 subtitle="容量を空けて、写真は残す",
 promotional="容量を最も使っている写真とビデオを確認し、Google ドライブ、Yandex Disk、コンピュータへ移動。削除前に必ず照合します。",
 keywords="ストレージ,空き容量,写真バックアップ,ビデオ,整理,Googleドライブ,クラウド,iPhone",
 description="""iPhone の容量がいっぱい。でも、どの写真も大切です。Spacekeeper は容量を使っているものを表示し、安全な場所へ移します。思い出を失わずに空き容量を取り戻せます。

• すべての写真とビデオをサイズ付きで大きい順に表示。年別・月別にも
• 移動、コピー、削除のみ。1 項目でも数百項目でも
• Google ドライブや Yandex Disk へ、年と月のフォルダに撮影日付きで保存
• アップロードはバックグラウンドで続行
• 削除前にクラウドのコピーをオリジナルと照合し、iOS が確認します
• オリジナルを写真アプリに復元。Live Photos にも対応
• ケーブルで Windows、macOS、Linux にバックアップ。インターネット不要
• アカウント不要、トラッキングなし、分析なし。オープンソース""")

broken = []
for lang, fields in L.items():
    for key, limit in LIMITS.items():
        size = len(fields[key])
        if size > limit:
            broken.append(f"{lang} {key}: {size} > {limit}")
for line in broken:
    print(line)
if not broken:
    out = pathlib.Path(__file__).with_name("listing.json")
    out.write_text(json.dumps(L, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(L)} languages within Apple's limits; wrote {out.name}")
sys.exit(1 if broken else 0)
