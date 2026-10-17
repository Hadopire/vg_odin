package vg

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:time"
import "core:strings"

FrameContext :: struct {
    index:           i64,
    arena:           virtual.Arena,
    allocator:       mem.Allocator,
    dt:              f32,
    time:            f32,
    resolution:      [2]f32,
    cursor:           [2]f32,
    swapchain:       GpuSwapchain,
    view_projection: matrix[4, 4]f32,
    cube_transform:  matrix[4, 4]f32,
    cube_color:      [4]f32,
    ui:              []^UiBox,
    os_events:       OsEventList,
    window:          WindowHandle,
}

UiWindowNode :: struct {
    next: ^UiWindowNode,
    prev: ^UiWindowNode,
    window: UiWindow,
    idx: int
}

UiWindowList :: struct {
    first: ^UiWindowNode,
    last: ^UiWindowNode,
}

AppContext :: struct {
    render_counter:  ^JobCounter,
    face:            GfxFontFace,
    ui_cache:        UiCache,
    cursor:          [2]f32,
    async_rendering: bool,
    done:            bool,

    test_windows: UiWindowList
}

@(private="file")
first_tick: time.Tick
@(private="file")
prev_tick: time.Tick

update :: proc(app: ^AppContext, frame: ^FrameContext) {
    for event := frame.os_events.first; event != nil; event = event.next {
        #partial switch event.kind {
        case .Window_Close:
            app.done = true
            return
        case .Mouse_Move:
            app.cursor.x = f32(event.pos_x)
            app.cursor.y = f32(event.pos_y)
        case .Window_Drag_Begin:
            app.async_rendering = false
        case .Window_Drag_End:
            app.async_rendering = true
        }
    }

    z    :: 5
    fov  :: 90
    near :: 0.1
    far  :: 100

    aspect := frame.resolution.x / frame.resolution.y
    tan_half := math.tan_f32(math.to_radians_f32(fov) * 0.5)
    half_height := tan_half * z
    half_width := half_height * aspect
    cube_position := [3]f32{
        (2 * app.cursor.x / frame.resolution.x - 1) * half_width,
        (1 - 2 * app.cursor.y / frame.resolution.y) * half_height,
        z,
    }

    eye := [3]f32{ 0, 0, 0 }
    target := [3]f32{ 0, 0, 1 }
    world_up := [3]f32{ 0, 1, 0 }
    forward := linalg.normalize(target - eye)
    right := linalg.normalize(linalg.cross(world_up, forward))
    up := linalg.cross(forward, right)

    view := matrix[4, 4]f32{
        right.x,   right.y,   right.z,   -linalg.dot(right, eye),
        up.x,      up.y,      up.z,      -linalg.dot(up, eye),
        forward.x, forward.y, forward.z, -linalg.dot(forward, eye),
        0,         0,         0,         1,
    }

    focal := 1 / tan_half
    depth_scale: f32 = far / (far - near)
    projection := matrix[4, 4]f32{
        focal / aspect, 0,     0,           0,
        0,              focal, 0,           0,
        0,              0,     depth_scale, -depth_scale * near,
        0,              0,     1,           0,
    }

    rotation := linalg.matrix4_rotate_f32(frame.time * 0.8, linalg.normalize([3]f32{ 0.4, 1, 0.2 }))
    frame.view_projection = projection * view
    frame.cube_transform = linalg.matrix4_translate_f32(cube_position) * rotation

    frame.cursor = app.cursor
    ui_begin(frame^, &app.ui_cache)
    ui_push_font_face(app.face)

    for node := app.test_windows.first; node != nil; {
        signal := ui_window_begin(fmt.tprintf("test_window##%v", node.idx), &node.window)
        ui_window_end()

        next := node.next
        if .Close in signal {
            dll_remove(&app.test_windows.first, &app.test_windows.last, node)
            free(node)
        } else if .Raise in signal {
            dll_remove(&app.test_windows.first, &app.test_windows.last, node)
            dll_push_front(&app.test_windows.first, &app.test_windows.last, node)
        }
        node = next
    }

    // fps counter

    @(static) time: f32
    @(static) frames: f32
    @(static) fps: f32
    time += frame.dt
    frames += 1
    if time >= 0.5 {
        fps = frames / time
        time = 0
        frames = 0
    }

    ui_push_pref_width({ kind = .Percent_Of_Parent, value = 1 })
    ui_push_pref_height({ kind = .Children_Sum, value = 1 })
    ui_row_begin({ .Floating_X, .Floating_Y })
        ui_spacer({ kind = .Percent_Of_Parent, value = 1 })
        str := fmt.aprint(int(fps), " fps", allocator = context.temp_allocator)
        ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
        ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
        ui_label(str)
        ui_pop_pref_height()
        ui_pop_pref_width()
        ui_spacer({ kind = .Pixels, value = 15, strictness = 1 })
    ui_row_end()
    ui_pop_pref_height()
    ui_pop_pref_width()

    // demo

    ui_push_pref_width({ kind = .Percent_Of_Parent, value = 1, strictness = 1 })
    ui_push_pref_height({ kind = .Children_Sum, strictness = 1 })
    ui_row_begin({.Draw_Background}, "menu_bar")
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_push_background_color({ 0.22, 0.24, 0.3, 1 })
    ui_push_corner_radius(4)
    ui_push_text_padding(8)
    ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
    ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
    for name in ([]string{ "File", "Edit", "View", "Window", "Help" }) {
        if .Clicked in ui_button(name).flags {
            fmt.println("clicked", name)
            if name == "Window" {
                node := new(UiWindowNode)
                node.window.rect.max = { 400, 300 }
                @(static) idx := 0
                node.idx = idx
                idx += 1
                dll_push_front(&app.test_windows.first, &app.test_windows.last, node)
            }
        }
    }
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_pop_text_padding()
    ui_pop_corner_radius()
    ui_pop_background_color()
    ui_row_end()

    ui_spacer({ kind = .Pixels, value = 24 })

    ui_push_pref_width({ kind = .Pixels, value = 500, strictness = 1 })
    ui_push_pref_height({ kind = .Pixels, value = 100, strictness = 1 })
    ui_push_background_color([4]f32{1,1,1,1})
    ui_push_text_color([4]f32{0,0,0,1})
    ui_row_begin({.Draw_Background}, "panel", { kind = .Percent_Of_Parent, value = 1 })

    ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
    ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
    ui_push_background_color({ 0.85, 0.3, 0.3, 1 })
    ui_push_text_padding(8)
    floating := ui_box_make({.Floating_X, .Floating_Y, .Draw_Background, .Draw_Text}, "Floating")
    floating.rel_position = { 300, 30 }
    ui_pop_text_padding()
    ui_pop_background_color()
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_push_pref_width({ kind = .Children_Sum, strictness = 1 })
    ui_push_pref_height({ kind = .Percent_Of_Parent, value = 1, strictness = 0 })
    ui_column_begin(padding = { kind = .Percent_Of_Parent, value = 1 })
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_push_pref_height({ kind = .Text_Content, strictness = 1})
    ui_push_pref_width({ kind = .Text_Content, strictness = 1})
    ui_label("->HELLO CENTER<-")
    ui_pop_pref_width()
    ui_pop_pref_height()

    ui_column_end()
    ui_row_end()

    ui_pop_text_color()
    ui_pop_background_color()
    ui_pop_pref_height()
    ui_pop_pref_width()

    ui_spacer({ kind = .Pixels, value = 16, strictness = 1 })

    ui_push_pref_width({ kind = .Pixels, value = 200, strictness = 1 })
    ui_push_pref_height({ kind = .Pixels, value = 40, strictness = 1 })
    ui_row_begin({.Clip, .Draw_Background, .Draw_Border}, "clip_demo")
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
    ui_push_pref_height({ kind = .Percent_Of_Parent, value = 1, strictness = 1 })
    ui_push_text_padding(8)
    ui_label("Clip:")
    if .Clicked in ui_button("JSUIS COUPE DU CUL").flags {
        fmt.println("clip click")
    }
    ui_pop_text_padding()
    ui_pop_pref_height()
    ui_pop_pref_width()
    ui_row_end()

    ui_spacer({ kind = .Pixels, value = 16, strictness = 1 })

    ui_push_pref_width({ kind = .Children_Sum, strictness = 1 })
    ui_push_pref_height({ kind = .Children_Sum, strictness = 1 })
    ui_row_begin()
    ui_pop_pref_height()
    ui_pop_pref_width()
    for name in ([]string{ "scroll_pixels", "scroll_percent" }) {
        flags := UiBoxFlags{.Clip, .View_Scroll_Y, .Draw_Background, .Draw_Border}
        if name == "scroll_percent" {
            flags += {.View_Scroll_Percent}
        }
        ui_push_pref_width({ kind = .Pixels, value = 200, strictness = 1 })
        ui_push_pref_height({ kind = .Pixels, value = 120, strictness = 1 })
        region := ui_column_begin(flags, name)
        ui_pop_pref_height()
        ui_pop_pref_width()

        ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
        ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
        ui_push_text_padding(8)
        for line in ([]string{ "Sloubi 1", "Sloubi 2", "Sloubi 3", "Sloubi 4", "Sloubi 5", "Sloubi 6", "ABOBA", "lbp", "fddr", "cclpo", "asdasdasd", "asdasdasd", "asdasdasd", "asdasdasd", "asdasdasd", "Asdasdasd", "asdasdasd"}) {
            ui_label(line)
        }
        ui_pop_text_padding()
        ui_pop_pref_height()
        ui_pop_pref_width()
        ui_column_end()
        ui_signal(region)

        ui_spacer({ kind = .Pixels, value = 16, strictness = 1 })
    }
    ui_row_end()

    long_text :: ```
    Unique représentante du genre des Enhydres (Enhydra), cette grosse loutre (classée dans la sous-famille des Lutrinés), avec un poids allant de 14 à 45 kg, diffère de toutes les autres espèces par sa capacité à pouvoir vivre en permanence immergée dans l’eau, à l’instar d’autres mammifères marins comme les Pinnipèdes. Elle est souvent aperçue nageant sur le dos, les mères faisant reposer leurs petits sur leur ventre. Son apparence atypique lui donne une allure intermédiaire entre les mammifères terrestres et marins.

    Elle fréquente les environnements côtiers où elle plonge jusqu'au fond pour se nourrir principalement d'invertébrés marins (oursins, divers mollusques et crustacés) et de certains poissons. Ses habitudes alimentaires sont remarquables : l'utilisation de pierres pour détacher ses proies ou briser des coquilles en fait l'un des rares mammifères à utiliser des outils. Considérée comme une espèce clé de voûte, elle régule les populations d'oursins qui, autrement, dévasteraient les écosystèmes des forêts de varech[1].

    Contrairement à d’autres mammifères au mode de vie comparable, sa protection thermique n'est pas assurée par une couche de graisse mais par une fourrure exceptionnellement dense, la plus épaisse du règne animal, comptant jusqu'à 170 000 poils par centimètre carré.

    Une fourrure de si bonne facture qu’elle fit l’objet d’une chasse intensive entre russes, japonais et britanniques entre 1741 et 1911, si bien que les populations mondiales, autrefois estimées entre 150 000 et 300 000 individus, ont chuté jusqu'à ne plus compter que 1 000 à 2 000 spécimens[2]. Grâce à une interdiction internationale de la chasse et à des efforts de conservation, l'espèce occupe aujourd'hui environ les deux tiers de son aire de répartition historique. Bien que ce rétablissement soit considéré comme un succès majeur de la conservation marine, l’espèce reste classée comme en danger en raison de la fragilité de certaines populations, notamment au Japon, en Californie et en Russie[3].

    Dénominations
    Nom scientifique valide : Enhydra lutris (Linneaus, 1758)[4] ;
    Synonymes :
    [afficher]
    Liste
    Nom normalisé anglais : Sea otter ;
    Nom vernaculaire normalisé locaux :
    Japonais : Rakko (ラッコ ; 海獺?, Issu de l’aïnou) ;
    Russe : Kalan ou Calan (en russe : Калан, Issu des langues des peuples autochtones du Kamtchatka) ;
    Nom typique en français : Loutre de mer[5] ;
    Nom vulgaire : Énhydre marine[6][7], Énhydre ;
    Noms vernaculaires : Loutre marine[8], Saricovienne (féminin ; désuet).
    Les noms « Loutre marine » et « Loutre de mer » sont partagées avec la loutre féline (Lontra felina)[9].

    Le nom générique, Enhydra, francisée en « Enhydre », dérive du grec ancien ἐν (en), signifiant « dans », et ὕδρα (hydra), signifiant « eau »[10], soit « dans l'eau ». L'épithète spécifique dérive du latin lutris, qui signifie « loutre »[11].

    Le nom Saricovienne fut un nom très utilisé en français pour désigner l’espèce dans les ouvrages de zoologie de la fin du XVIIIe siècle jusque dans certains ouvrages du XXe siècle, notamment dans l’Histoire naturelle de Buffon. Selon la mention qui en est fait dans cet ouvrage, le nom tiendrai son origine des langues du Brésil et désigne originellement la loutre géante (Pteronura brasiliensis) et se prononçait relativement différemment de la manière dont il s’écrivait. C’est pour cette raison que le terme a fini par se raréfier au cours du XIXe siècle, où il est aujourd’hui considéré comme un terme désuet ou archaïque.

    Pour autant, dans certaines langues comme le japonais, l’Énhydre n’est pas toujours considérée comme une version marine avec un quelconque lien sémantique avec la « loutre » (Lutra, Lontra, Aonyx etc…), comme l’espèce est le plus souvent écrit en katakana.

    Dans le contexte de sa chasse et de son commerce pour la fourrure, elle était autrefois parfois désignée sous le nom de « castor de mer »[12].

    Taxonomie et systématique
    Histoire

    Illustration d'une loutre de mer basé sur les descriptions de Steller, XIXe siècle.
    La première description scientifique de la loutre de mer a été réalisée par Georg Steller[13]. Il participait à la Deuxième expédition de Kamtchatka sous le commandement de Vitus Béring. Le navire de l'expédition fit naufrage au large des Îles du Commandeur, et les marins furent contraints de passer l'hiver 1741-1742 sur la plus grande île de l'archipel, nommée plus tard Île Béring. Grâce à la chasse aux animaux marins, et en particulier aux loutres de mer, de nombreux membres de l'expédition purent survivre à des conditions hivernales extrêmes ; sur 78 personnes, seules 47 survécurent ; Béring lui-même figura parmi les victimes. Georg Steller, naturaliste de l'expédition, tenait des notes régulières. Dix ans plus tard, après la mort de Steller, l'Académie impériale des sciences publia son ouvrage De Bestiis Marinis, or The Beasts of the Sea, contenant une description détaillée des animaux marins de l'île, incluant une étude très approfondie de plusieurs pages sur la loutre de mer[13]. Cette édition du XVIIIe siècle resta la source principale sur les loutres de mer pendant les 200 années suivantes, car personne d'autre ne se consacra à l'étude de l'animal dans la nature avant les années 1930[14].

    À partir de 1751, plusieurs chercheurs tentèrent de classifier l'animal en se basant sur la description de Steller ainsi que sur les peaux et squelettes rapportés en Europe. Elle fut décrite pour la première fois dans la taxonomie moderne dès la première édition valide du Systema Naturae de Carl von Linné, la dixième, sortie en 1758, l’animal portant le protonyme de Mustela lutris[15]. En raison de ses caractéristiques morphologiques uniques qui l'éloignent des autres espèces, sa classification fut révisée à plusieurs reprises. Steller lui-même, puis Johann Christian Erxleben, classèrent la loutre de mer dans le genre des loutres communes (Lutra)[13],[16]. Carl von Linné la plaça dans le genre Mustela[17], tandis que Pallas l'associa aux phoques dans le genre Phoca[18].

    Au milieu du XIXe siècle, la loutre de mer fut finalement isolée dans un genre distinct, Enhydra, par le naturaliste écossais John Fleming en 1822 sur la base de différence dans le nombre de dents, la longueur de la queue ainsi que par l’absence de sac odorant au niveau de l'anus [19]. Cependant, la polémique scientifique sur l'opportunité de regrouper ce genre avec les loutres dans la sous-famille des Lutrinae se poursuivit jusqu'au milieu du XXe siècle ; le genre Latax sera également très utilisé avant d'être définitivement supplanté sous la dénomination binominale Enhydra lutris par ancienneté en 1922[20]. Aujourd'hui, le genre Enhydra y est officiellement inclus. La conclusion finale sur sa classification a été facilitée par l'étude des restes fossiles de loutres du Miocène et du Pliocène (Potamotherium dubia, Aonyx hessica et Enhydra reevei), reconnus comme des formes de transition entre la loutre de mer moderne et les autres genres de la sous-famille[21],[22].

    Sous-espèces
    Sous-espèces de Enhydra lutris selon ITIS (22 mars 2026)[23]
    Sous-espèce	Répartition géographique	Description et caractéristiques
    Enhydra lutris lutris
    (Linnaeus, 1758)	Des îles Kouriles jusqu'aux îles du Commandeur (Pacifique Nord-Ouest).	Sous-espèce la plus massive. Crâne proportionnellement plus large et os nasaux plus courts que chez les autres taxons[24].
    Enhydra lutris kenyoni
    (Wilson, 1991)
    	Des îles Aléoutiennes (Alaska) jusqu'à l'Oregon.	Se distingue par une mâchoire nettement plus longue[24],[25].
    Enhydra lutris nereis
    (Merriam, 1904)


    Côtes du centre et du sud de la Californie.	Présente un museau plus allongé et une denture de taille plus réduite[24],[26].
    Évolution
    La loutre de mer est le membre le plus massif de la famille des mustélidés, et bien plus trapu comparée à d’autres espèces de lutrinés comme la Loutre géante, bien plus longue et svelte[27], un groupe diversifié qui comprend les 14 espèces de loutres et des animaux terrestres tels que les belettes, les blaireaux et les visons. Elle est unique parmi les mustélidés car elle ne construit ni gîte ni terrier, ne possède pas de glandes anales fonctionnelles[28] et peut passer l'intégralité de sa vie sans quitter l'eau[29]. Seul membre vivant du genre Enhydra, la loutre de mer est si différente des autres mustélidés qu'en 1982 encore, certains scientifiques pensaient qu'elle était plus proche des phoques[30].

    Les analyses génétiques indiquent que la loutre de mer et ses plus proches parents actuels, qui incluent la Loutre à cou tacheté, la Loutre d'Eurasie, la Loutre du Cap et la Loutre cendrée, partageaient un ancêtre commun il y a environ 5 millions d'années[31].

    Les preuves fossilifères indiquent que la lignée des Énhydres s'est isolée dans le Pacifique Nord il y a environ 2 millions d'années, donnant naissance à l'espèce aujourd'hui éteinte Enhydra macrodonta et à l’Énhydre marine moderne, Enhydra lutris[20]. Une espèce apparentée, Enhydra reevei, a été décrite à partir de fossiles du Pléistocène provenant d'Angleterre de l'Est[32]. La loutre de mer moderne a d'abord évolué dans le nord de Hokkaidō et en Russie, avant de s'étendre vers l'est jusqu'aux îles Aléoutiennes, l'Alaska, puis de descendre le long de la côte nord-américaine[33]. Par rapport aux cétacés, aux siréniens et aux pinnipèdes, qui sont entrés dans l'eau il y a respectivement environ 50, 40 et 20 millions d'années, la loutre de mer est une nouvelle venue dans l’écosystème marin[34]. À certains égards, cependant, elle est plus totalement adaptée à l'eau que les pinnipèdes, qui doivent s'échouer sur terre ou sur la glace pour mettre bas[35]. Le génome complet de Enhydra lutris kenyoni a été séquencé en 2017, permettant d'étudier sa divergence évolutive par rapport aux mustélidés terrestres[36].

    Depuis leur divergence d'avec leur ancêtre commun il y a cinq millions d'années, les loutres de mer ont développé des traits dépendant d'une sélection polygénique. Cela a mené à l'évolution de nombreuses caractéristiques distinctives, telles qu'une fourrure épaisse et huileuse et des os de grande taille, par rapport à leurs espèces sœurs d'eau douce[37]. Ces traits sont indispensables pour survivre dans les eaux froides du Pacifique Nord, où elles passent toute leur vie, bien que les loutrons sortent occasionnellement de l'eau. Les loutres de mer possèdent la fourrure la plus dense de tout le règne animal, avec environ 150 000 poils/cm2, car elles ne possèdent pas de couche de graisse, tandis que leurs glandes sébacées aident à imperméabiliser leur pelage pour empêcher l'air de s'en échapper[38]. Une étude comparant les populations méridionales et septentrionales d’énhydres et de la loutre du Cap a déterminé que les traits aquatiques, tels que la perte de l'odorat et l'épaisseur du poil, ont évolué de manière indépendante[37].

    Historiquement, les loutres de mer ont subi de nombreux goulots d'étranglement génétiques. Des réductions massives d'effectifs ont eu lieu il y a environ 10 000 générations, puis il y a 300 à 700 générations, bien avant le début de la traite des fourrures[37]. Ces épisodes anciens sont responsables de la faible diversité génétique déjà présente chez l'espèce, rendant le goulot d'étranglement secondaire causé par la chasse au XVIIIe siècle encore plus critique. Ces déclins primaires étaient probablement dus à des maladies, laissant parfois seulement dix à quarante individus survivants pendant plusieurs décennies[37]. Cela a entraîné une dérive génétique, isolant les populations du Nord et du Sud par des milliers de kilomètres. Cependant, le goulot d'étranglement moderne causé par le commerce des fourrures entre le XVIIIe siècle et le début du XXe siècle reste la préoccupation majeure des conservateurs, chaque réduction de population augmentant le risque de dérive génétique délétère.

    Phylogénie
    Les relations phylogénétiques au sein de la sous-famille des lutrinés montrent que l’énhydre appartient à un clade distinct de celui de la loutre géante (Pteronura), cette dernière étant la forme la plus basale du groupe. Les analyses génétiques suggèrent une divergence d'avec ses plus proches parents actuels il y a environ 5 millions d'années[39].

     Lutrinae 	

     Pteronura (Loutre géante)




     Lontra (4 espèces)




     Enhydra (Loutre de mer)



     Hydrictis (Loutre à cou tacheté)




     Lutra (2 espèces)




     Aonyx (Loutres à joues blanches)




     Amblonyx (Loutre cendrée)



     Lutrogale (Loutre à pelage lisse)








    Description
     v · d · m  Formule dentaire
    mâchoire supérieure
    1	3	1	3	3	1	3	1
    2	3	1	2	2	1	3	2
    mâchoire inférieure
    Total : 32
    Dentition de Enhydra lutris.

    Une loutre de mer hors de l’eau. La corps étant visible en entier, sa physionomie particulière est parfaitement perceptible.
    La loutre de mer est l'une des plus petites espèces de mammifères marins, mais elle est le plus lourd des mustélidés[29]. Les mâles pèsent généralement entre 22 et 45 kg pour une longueur de 1,2 à 1,5 m, bien que des spécimens atteignant 54 kg aient été enregistrés[40]. Les femelles sont plus petites, pesant de 14 à 33 kg pour une longueur de 1,0 à 1,4 m[41]. Le poids moyen des énhydres adultes vivant dans des zones densément peuplées, soit 28,3 kg pour les mâles et 21,1 kg pour les femelles, est bien plus léger que le poids moyen des individus des populations plus éparses, qui s'élève à 39,3 kg pour les mâles et 25,2 kg pour les femelles[2]. On suppose que les individus des populations moins denses sont davantage capables de monopoliser les sources de nourriture[2]. Pour sa taille, le baculum du mâle est très grand, massif et recourbé vers le haut, mesurant 150 mm de long et 15 mm à la base[42].


    Patte postérieur de l’énhydre, semblable à une nageoire de pinipède.
    Contrairement à la plupart des autres mammifères marins, la loutre de mer ne possède pas de graisse et compte sur sa fourrure exceptionnellement épaisse pour rester au chaud[43]. Avec jusqu'à 150 000 poils/cm2, sa fourrure est la plus dense de tous les animaux[44],[45]. La fourrure se compose de longs jarres imperméables et d'un sous-poil court ; les jarres maintiennent la couche de sous-poil dense au sec. Un compartiment d'air se trouve entre la fourrure épaisse et la peau, où l'air est emprisonné et chauffé par le corps[46]. L'eau froide est maintenue totalement à l'écart de la peau et la perte de chaleur est limitée[41]. Cependant, un inconvénient potentiel de ce mode d'isolation est la compression de la couche d'air lorsque l’énhydre plonge, réduisant ainsi la qualité isolante de la fourrure en profondeur lorsque l'animal cherche sa nourriture[46]. La fourrure est épaisse toute l'année, car elle tombe et se remplace progressivement plutôt que lors d'une saison de mue distincte[47]. Comme la capacité des poils de jarres à repousser l'eau dépend d'une propreté absolue, la loutre de mer a la capacité d'atteindre et de se toiletter sur n'importe quelle partie de son corps, profitant de sa peau lâche et d'un squelette souple[48]. La coloration du pelage est généralement brun foncé avec des mouchetures gris argenté, mais elle peut varier du brun jaunâtre ou grisâtre au noir presque total[49]. Chez les adultes, la tête, la gorge et la poitrine sont plus claires que le reste du corps[49].

    La loutre de mer présente de nombreuses adaptations à son environnement marin. Les narines et les petites oreilles peuvent se fermer[50]. Les pattes postérieures, qui fournissent l'essentiel de la propulsion pour la nage, sont longues, largement aplaties et entièrement palmées[51]. Le cinquième doigt de chaque patte postérieure est le plus long, ce qui facilite la nage sur le dos, mais rend la marche sur terre difficile[52]. La queue est assez courte, épaisse, légèrement aplatie et musclée. Les pattes avant sont courtes avec des griffes rétractiles, munies de coussinets robustes sur les paumes qui permettent de saisir des proies glissantes[53]. Les os présentent une ostéosclérose[54], augmentant leur densité pour réduire la flottabilité.

    La loutre de mer offre un aperçu du processus évolutif de l’appropriation de l’environnement aquatique par les mammifères qui s'est produit de nombreuses fois au cours de l'évolution des animaux de cette classe[55]. N'étant retournée à la mer qu'il y a environ 3 millions d'années[56], l’énhydre représente un instantané du point le plus précoce de la transition de la fourrure vers la couche de graisse ; la fourrure est toujours avantageuse, compte tenu de sa petite taille et de la division de son temps de vie entre les milieux aquatique et terrestre[57]. Cependant, à mesure que ces loutres évoluent et s'adaptent à passer de plus en plus de temps en milieu marin, le principe de l’évolution convergente tend à supposer que la dépendance à la fourrure pour l'isolation sera remplacée par la suite à une dépendance à la graisse. Cela est particulièrement vrai en raison de la nature de l’animal à plonger en profondeur ; à mesure que ces comportements deviennent plus preignants, la faisant plonger toujours plus profondément et plus longtemps, la capacité de la couche d'air à retenir la chaleur ou la flottabilité diminue[46], tandis que la graisse reste efficace pour ces deux fonctions[57], notamment pour servir de source d'énergie supplémentaire lors des plongées les plus profondes[58].

    La loutre de mer se propulse sous l'eau en déplaçant l'arrière de son corps, y compris sa queue et ses pattes postérieures, de haut en bas[51], et est capable d'atteindre des vitesses allant jusqu'à 9 km/h[27]. Sous l'eau, son corps est long et profilé, avec les membres antérieurs courts pressés étroitement contre la poitrine[59]. À la surface, elle flotte généralement sur le dos et se déplace en agitant ses pattes et sa queue de droite à gauche[60]. Au repos, les quatre membres peuvent être repliés sur le torse pour conserver la chaleur, tandis que lors des journées particulièrement chaudes, les pattes postérieures peuvent être maintenues sous l'eau pour se rafraîchir[61]. Le corps de l’énhydre flotte aisément en raison de sa grande capacité pulmonaire, environ 2,5 fois plus grande que celle des mammifères terrestres de taille similaire[62], ainsi que grâce à l'air emprisonné dans sa fourrure. Sur la terre ferme, elle et très maladroite et est contrainte de marcher en se dandinant, et de sautiller vers l’avant pour courir[52].

    De longues vibrisses très sensibles et les pattes avant aident l’animal à trouver ses proies par le toucher lorsque les eaux sont sombres ou troubles[63]. Les chercheurs ont noté que lorsqu'ils approchent à découvert, les sujets réagissent plus rapidement lorsque le vent souffle vers eux, indiquant que le sens de l'olfaction est plus important que la vue comme sens d'alerte[64]. D'autres observations indiquent que la vue de l’énhydre est utile sur et sous l'eau, bien qu'elle ne soit pas aussi bonne que celle des phoques[65]. Son ouïe n'est ni particulièrement fine ni médiocre[66].

    Les 32 dents d'un adulte, particulièrement les molaires, sont aplaties et arrondies pour broyer plutôt que pour couper la nourriture[67]. Les phoques et les énhydres sont les seuls carnivores possédant deux paires d'incisives inférieures au lieu de trois[68]. Les dents et les os sont parfois tachés de pourpre en raison de l'ingestion d'oursins[69].

    L’espèce a un taux métabolique deux ou trois fois supérieur à celui des mammifères terrestres de taille comparable. Elle doit manger environ 25 à 38 % de son propre poids corporel en nourriture chaque jour pour brûler les calories nécessaires afin de contrer la perte de chaleur due à l'environnement d'eau froide[70],[71]. Son efficacité digestive est estimée à 80–85 %[72], et la nourriture est digérée et évacuée en seulement trois heures[43]. La majeure partie de ses besoins en eau est satisfaite par la nourriture, bien que, contrairement à la plupart des autres mammifères marins, elle boit également de l'eau de mer. Ses reins relativement grands lui permettent de tirer de l'eau douce de l'eau de mer et d'excréter une urine très concentrée[73].

    Comportement

    Des vibrisses sensibles et les pattes avant permettent aux loutres de mer de trouver leurs proies (comme cet oursin violet) en utilisant leur sens du toucher.
    La loutre de mer a une activité diurne. Elle connaît une période de recherche de ressources alimentaires le matin, commençant environ une heure avant le lever du soleil, puis se repose ou dort en milieu de journée[74]. La quête de nourriture reprend pendant quelques heures l'après-midi et s'apaise avant le coucher du soleil ; une troisième période peut survenir vers minuit[74]. Les femelles avec des petits semblent plus enclines à se nourrir la nuit[74]. Les observations consacrées à l'alimentation routinière varient de 24 % à 60 %, dépendant apparemment de la disponibilité de la nourriture dans la zone[75].

    Elles passent une grande partie de leur temps à se toiletter, ce qui consiste à nettoyer la fourrure, démêler les nœuds, éliminer les poils morts, frotter le pelage pour en extraire l'eau et y introduire de l'air. Pour un observateur occasionnel, l'animal semble se gratter, mais elles ne sont pas connues pour avoir des poux ou d'autres parasites dans leur fourrure[76]. Lorsqu'elles mangent, les énhydres effectuent de fréquentes rotations dans l'eau, apparemment pour rincer les débris alimentaires de leur pelage[77].


    Une loutre de mer se toilettant en frottant son pelage dense.
    Recherche de nourriture
    L’espèce chasse lors de courtes plongées, souvent jusqu'au fond marin. Bien qu'elle puisse retenir sa respiration jusqu'à cinq minutes[50], ses plongées durent généralement une minute et rarement plus de quatre minutes[41]. C'est le seul animal marin capable de soulever et de retourner des rochers, ce qu'elle fait souvent avec ses pattes avant pour chercher des proies[77]. La loutre de mer peut également cueillir des escargots et d'autres organismes dans le varech ou creuser profondément dans la vase pour trouver des palourdes[77]. C'est le seul mammifère marin qui capture des poissons avec ses pattes avant plutôt qu'avec ses dents[43].

    Sous chaque patte avant, l’énhydre possède une poche de peau lâche qui s'étend sur la poitrine. Dans cette poche, généralement dans la partie gauche, l'animal y stocke la nourriture récoltée pour la ramener à la surface, et parfois une pierre utilisée pour briser les coquillages[78]. À la surface, elle mange en flottant sur le dos, utilisant ses pattes avant pour déchiqueter la nourriture. Elle peut mâcher et avaler de petites moules avec leurs coquilles, tandis que les plus grosses sont ouvertes par torsion[79]. Elle utilise ses incisives inférieures pour accéder à la chair des mollusques[80].

    Pour manger les gros oursins, recouverts de piquants, elle mord la face inférieure où les piquants sont les plus courts et lèche le contenu mou de la carapace[79].

    L'utilisation de pierres pour chasser et se nourrir fait de la loutre de mer l'une des rares espèces de mammifères à utiliser des outils[81]. Pour ouvrir les coquilles dures, elle peut frapper sa proie avec ses deux pattes contre une pierre posée sur sa poitrine. Pour détacher un ormeau de son rocher, elle martèle la coquille avec une grosse pierre à un rythme observé de 45 coups en 15 secondes[41]. Le détachage un ormeau, qui peut s'agripper au rocher avec une force égale à 4 000 fois son propre poids, nécessite souvent plusieurs plongées[41].

    Structure sociale

    Des loutres de mer dorment en se tenant la patte, maintenues à flot par leur flottabilité naturelle élevée.
    Bien que chaque adulte et juvénile indépendant chasse seul, les loutres de mer ont tendance à se reposer ensemble en groupes non mixtes. Un groupe contient généralement 10 à 100 animaux, les groupes de mâles étant plus grands que ceux des femelles[82]. Le plus grand groupe jamais observé comptait plus de 2 000 individus. Pour éviter de dériver vers le large pendant le repos, elles s'enroulent souvent dans le varech[83].

    Un mâle a plus de chances de s'accoupler s'il maintient un territoire de reproduction dans une zone privilégiée par les femelles[84]. L'automne étant le pic de reproduction, les mâles ne défendent généralement leur territoire que du printemps à l'automne[84]. Durant cette période, ils patrouillent les limites pour exclure les autres mâles[84], bien que les combats réels soient rares[82]. Les femelles se déplacent librement entre les territoires des mâles, où elles sont en moyenne cinq fois plus nombreuses que les mâles adultes[84]. Les mâles sans territoire se rassemblent dans de grands groupes de célibataires[84].

    L'espèce possède un répertoire vocal varié : le cri d'un petit est souvent comparé à celui d'une mouette[85]. Les femelles roucoulent lorsqu'elles semblent satisfaites ; les mâles peuvent émettre des grognements[86]. En cas de détresse ou de peur, les adultes sifflent, soufflent ou, dans des cas extrêmes, hurlent[85].

    En captivité, des liens de type « fratrie » ont été observés. Au Shedd Aquarium, deux femelles, Kiana et Cayucos, entretenaient une relation de grande et petite sœur, la plus jeune imitant les jeux de l'aînée[87]. Des analyses préliminaires de l'Université de Californie à Santa Cruz suggèrent que ces groupes ne sont pas des assemblages aléatoires, mais contiennent des clusters distincts d'individus ayant des associations durables sur plusieurs années[88].

    Reproduction et cycle de vie

    Pendant l'accouplement, le mâle mord le nez de la femelle, le laissant souvent ensanglanté et blessé.
    Les loutres de mer sont polygynes. Lorsqu'un mâle trouve une femelle réceptive, les deux s'engagent dans un comportement joueur et parfois agressif. Ils forment un lien pour la durée de l'œstrus (environ 3 jours). Le mâle maintient la tête ou le nez de la femelle avec ses mâchoires pendant la copulation, laissant souvent des cicatrices visibles[27] [89].

    Les naissances ont lieu toute l'année, avec des pics entre mai et juin au nord, et entre janvier et mars au sud[90]. La gestation varie de quatre à douze mois car l'espèce est capable d’ovulations différée[90]. En Californie, elles se reproduisent généralement chaque année, deux fois plus souvent qu'en Alaska[91].

    La mise bas a lieu dans l'eau et produit généralement un seul petit pesant de 1,4 à 2,3 kg[92] . Les jumeaux surviennent dans 2 % des cas, mais un seul survit généralement[27]. À la naissance, les yeux sont ouverts et dix dents sont visibles. Le pelage de naissance est si dense et contient tant d'air que le petit flotte comme un bouchon et ne peut pas plonger[93]. Cette fourrure est remplacée par le pelage adulte vers 13 semaines[15].


    Une mère flotte avec son petit sur la poitrine. Georg Steller a écrit : « Elles embrassent leurs petits avec une affection à peine croyable. »[94]
    L'allaitement dure 6 à 8 mois en Californie et 4 à 12 mois en Alaska. La mère commence à offrir des morceaux de proies vers 1 ou 2 mois[95]. Le lait, provenant de deux mamelles abdominales, est très riche en graisses. Le jeune s'exerce à nager et plonger pendant plusieurs semaines avant de pouvoir atteindre le fond. Les juvéniles sont indépendants vers 6 ou 8 mois, mais une mère peut être forcée d'abandonner un petit si elle ne trouve pas assez de nourriture[96]. La mortalité des petits est élevée, seul environ 25 % survivent à leur première année[96].

    Les femelles s'occupent seules des petits. Une mère porte son nourrisson sur sa poitrine pour l'isoler de l'eau froide et le toilette attentivement[97]. Lorsqu'elle chasse, elle laisse son petit flotter, parfois amarré à du varech pour qu'il ne dérive pas[98].

    Les femelles atteignent la maturité sexuelle vers 3 ou 4 ans, les mâles vers 5 ans. Dans la nature, elles vivent jusqu'à 23 ans[41], avec une moyenne de 10-15 ans pour les mâles et 15-20 ans pour les femelles[99]. L'usure des dents est souvent une cause de fin de vie dans la nature[100].

    Population et répartition
    Les loutres de mer vivent dans les eaux côtières d'une profondeur de 15 à 23 m[101] et restent généralement à moins d'un kilomètre du rivage[102]. On les trouve le plus souvent dans des zones protégées des vents océaniques les plus violents, telles que les côtes rocheuses, les denses forêts de varech et les récifs barrières[103]. Bien qu'elles soient plus fortement associées aux substrats rocheux, les loutres de mer peuvent également vivre dans des zones où le fond marin est principalement constitué de boue, de sable ou de limon[104]. Leur limite septentrionale est fixée par la glace, car les loutres de mer peuvent survivre au milieu de la banquise de mer mais pas sur la glace de rive[105]. Les individus occupent généralement un domaine vital de quelques kilomètres de long et y restent toute l'année[106].

    On estime que la population de loutres de mer était autrefois de 150 000 à 300 000 individus[12], s'étendant en arc de cercle à travers le Pacifique Nord, du nord du Japon jusqu'au centre de la péninsule de Basse-Californie au Mexique. La traite des fourrures qui a débuté dans les années 1740 a réduit le nombre de loutres de mer à environ 1 000 à 2 000 individus répartis dans 13 colonies. Les registres de chasse étudiés par l'historienne Adele Ogden placent la limite occidentale des zones de chasse au large de l'île japonaise de Hokkaido et la limite orientale au large de Punta Morro Hermosa, à environ 35 km au sud de Punta Eugenia, le cap le plus à l'ouest de la Basse-Californie du Sud au Mexique[107].

    Dans environ les deux tiers de son ancienne aire de répartition, l'espèce se trouve à différents stades de rétablissement, avec de fortes densités de population dans certaines zones et des populations menacées dans d'autres. Les loutres de mer ont actuellement des populations stables dans certaines parties de la côte est de la Russie, en Alaska, en Colombie-Britannique, dans l'État de Washington et en Californie, avec des rapports de recolonisation au Mexique et au Japon[108]. Les estimations de population réalisées entre 2004 et 2007 donnaient un total mondial d'environ 107 000 loutres de mer[15],[109],[110],[111],[112]. Cependant, des comptages beaucoup plus récents dans des zones telles que les Îles Aléoutiennes en Alaska et la Mer d'Okhotsk le long des côtes russes ont montré des déclins abrupts ces dernières années, jetant un doute sur ces estimations[113],[114].

    Japon
    Bien avant les relations diplomatiques avec le Japon, le naturaliste Georges Cuvier écrivait dans son règne animal que la loutre de mer faisait l’objet d’une chasse intensive par les Japonais. Adele Ogden précise dans un écrit issu du The California Sea Otter Trade que les loutres de mer étaient chassées « de Yezo vers le nord-est en passant par le groupe des Kouriles et la péninsule du Kamtchatka jusqu'à la chaîne des Aléoutiennes »[107]. « Yezo » fait référence à la province insulaire de Hokkaido, dans le nord du Japon, où réside la seule population confirmée de loutres de mer du pays[5]. Des observations ont été documentées dans les eaux du Cap Nosappu, de Erimo, de Hamanaka et de Nemuro, entre autres localités de la région[115].

    Le dernier comptage estimait à environ 50 le nombre de loutres de mer vivant au large de l'est de Hokkaido. La Fondation Etopirika (エトピリカ基金), une petite organisation à but non lucratif dirigée par Yoshihiro Kataoka, surveille la population locale et recherche des moyens de les protéger[116]. En avril 2025, Kataoka a documenté le premier cas mortel de influenza aviaire chez les loutres de mer au Japon[117].

    Russie
    La majeure partie de la population de L. l. lutris se trouve le long du littoral de l'Extrême-Orient russe, dans les eaux du Pacifique Nord-Ouest au large du pays (notamment au Kamtchatka et sur l'île de Sakhaline), et est occasionnellement aperçue dans et autour de la Mer d'Okhotsk[118]. Avant le XIXe siècle, environ 20 000 à 25 000 loutres de mer vivaient près des Îles Kouriles, et davantage près du Kamtchatka et des Îles du Commandeur. Après les années de la Grande Chasse, la population dans ces zones n'était plus que de 750[109]. En 2004, les loutres de mer avaient repeuplé tout leur ancien habitat dans ces régions, avec une population totale estimée à l'époque à environ 27 000 individus ; parmi eux, environ 19 000 se trouvaient aux Kouriles, 2 000 à 3 500 au Kamtchatka et 5 000 à 5 500 aux îles du Commandeur[109].

    Cependant, des relevés beaucoup plus récents réalisés entre 2019 et 2024 ont montré des déclins spectaculaires dans toutes ces populations. Les derniers chiffres placent le nombre de loutres de mer autour des îles Kouriles à seulement 3 000, et à 1 673 et 1 565 autour des îles du Commandeur et de la péninsule du Kamtchatka respectivement[113],[114]. On pense que le braconnage illégal persistant en Russie contribue à ces déclins[113],[119]. Des ONG russes telles que la Nature and People Foundation ont intensifié leurs efforts pour attirer l'attention sur la détresse de la population de loutres de mer en Russie[120].

    Colombie-Britannique
    Le long de la côte nord-américaine au sud de l'Alaska, l'aire de répartition de la loutre de mer est discontinue. Une population relique a survécu au off de l'Île de Vancouver jusqu'au XXe siècle, mais elle s'est éteinte malgré le traité de protection internationale de 1911, la dernière loutre ayant été capturée près de Kyuquot en 1929. De 1969 à 1972, 89 loutres de mer ont été transportées par avion ou par bateau de l'Alaska vers la côte ouest de l'île de Vancouver. Cette population est passée à plus de 5 600 individus en 2013 avec un taux de croissance annuel estimé à 7,2 %, et leur aire de répartition sur la côte ouest de l'île s'est étendue vers le nord jusqu'au cap Scott, à travers le détroit de la Reine-Charlotte jusqu'à l'Archipel Broughton, et vers le sud jusqu'à Clayoquot Sound et Tofino[121]. En 1989, une colonie distincte a été découverte sur la côte centrale de la Colombie-Britannique. On ne sait pas si cette colonie, qui comptait environ 300 animaux en 2004, a été fondée par des populations transplantées ou s'il s'agissait d'une population relique passée inaperçue[111]. En 2013, cette population dépassait les 1 100 individus. En 2007, le Canada a déterminé que le statut des loutres de mer était « préoccupant »[122].

    États-Unis
    Alaska
    L'Alaska est la zone centrale de l'aire de répartition de la loutre de mer. En 1973, la population en Alaska était estimée entre 100 000 et 125 000 individus[123]. En 2006, cependant, elle était tombée à environ 73 000[110]. Un déclin massif dans les îles Aléoutiennes explique la majeure partie de ce changement ; la cause n'est pas connue avec certitude, bien que la prédation par les orques soit suspectée[124]. La population du Détroit du Prince-William a également été gravement touchée par la marée noire de l'Exxon Valdez en 1989[77].

    Washington
    En 1969 et 1970, 59 loutres de mer ont été transférées de l'île d'Amchitka vers l'État de Washington. La population est passée de quelques dizaines d'individus à plus de 2 000 en 2017. Leur aire de répartition s'étend de Point Grenville au sud jusqu'au Cap Flattery au nord[15]. Dans cet État, les loutres se trouvent presque exclusivement sur les côtes extérieures.

    Oregon
    La dernière loutre de mer indigène de l'Oregon a probablement été abattue en 1906. Les tentatives de réintroduction en 1970 et 1971 ont échoué[125]. Depuis, seules des observations isolées d'individus errants en provenance de Washington ou de Californie ont été confirmées[126].

    Californie

    Les zones reculées du littoral californien ont abrité de petites colonies de loutres de mer pendant la traite des fourrures. Les 50 individus ayant survécu, redécouverts en 1938, se sont depuis multipliés pour atteindre près de 3 000.
    La population historique de loutres de mer de Californie était estimée à 16 000 individus avant que la traite des fourrures ne décime la population, menant à leur extinction présumée. La population actuelle descend d'une unique colonie d'environ 50 loutres de mer située près du Bixby Creek Bridge en mars 1938[127]. Leur aire de répartition principale s'est progressivement étendue de Pigeon Point dans le Comté de San Mateo jusqu'au Comté de Santa Barbara[128].

    Les loutres de mer étaient autrefois nombreuses dans la Baie de San Francisco[129]. Les archives historiques révèlent que la Compagnie russe d'Amérique a introduit clandestinement des Aléoutes dans la baie à plusieurs reprises, malgré les tentatives espagnoles de les capturer ou de les abattre alors qu'ils chassaient la loutre dans les estuaires de San Jose, San Mateo, San Bruno et autour de l'île Angel[107]. Le fondateur de Fort Ross, Ivan Kuskov, trouvant les loutres rares lors de son second voyage à Bodega Bay en 1812, envoya un groupe d'Aléoutes dans la baie de San Francisco ; ils y rencontrèrent d'autres groupes russes et américains et capturèrent 1 160 loutres en trois mois[130]. En 1817, les loutres de la région étaient pratiquement éliminées. En 1833, les trappeurs George Nidever et George Calvert Yount explorèrent la baie en canoë et rapportèrent des peaux de loutres de mer, de castors et de loutres de rivière. Quelques populations reliques ont pu survivre dans la baie jusqu'en 1840 au niveau de l'embouchure du Corte Madera Creek[131].

    À la fin des années 1980, le U.S. Fish and Wildlife Service (USFWS) a transféré environ 140 loutres de mer du Sud vers l'Île San Nicolas afin d'établir une population de réserve. À la surprise des biologistes, la majorité de ces loutres sont retournées vers le continent à la nage[132] .Un autre groupe de vingt individus a nagé 119 km vers le nord jusqu'à l'île San Miguel, où ils ont été capturés et retirés[133]. En 2005, il ne restait que 30 loutres à San Nicolas, bien que leur nombre augmente lentement grâce à l'abondance des proies[134] . En 2016, le comptage à San Nicolas était de 104 individus, confirmant une croissance annuelle de plus de 12 % sur 5 ans[135] En 2011, des loutres ont été observées au sud, près de Laguna Beach et San Diego, pour la première fois en 30 ans.

    L'USFWS a tenté en 1986 une « gestion zonale » en déclarant une « zone sans loutre » entre Point Conception et la frontière mexicaine pour limiter la compétition avec les pêcheries. Ce plan a été abandonné car il s'est avéré impossible de capturer les centaines de loutres qui ignoraient les limites. Le 19 décembre 2012, l'USFWS a officiellement déclaré l'échec de cette expérience et protège désormais les loutres colonisant les côtes au sud de Point Conception comme espèce menacée.

    Bien que la population californienne se soit étendue depuis 1911, elle a stagné ou reculé entre 2007 et 2010. Une toxine, la microcystine, produite par des cyanobactéries (Microcystis) issues du ruissellement agricole, semble empoisonner les loutres via les coquillages qu'elles consomment[136]. De plus, les attaques de grands requins blancs sont en forte augmentation : bien qu'ils ne mangent pas les loutres (trop pauvres en graisse), leurs morsures sont responsables d'une part croissante de la mortalité (passant de 8 % dans les années 1980 à 30 % en 2010).


    Une loutre de mer dans une forêt de varech au large de la côte centrale de Californie.
    Pour que la loutre de mer du Sud soit retirée de la liste des espèces menacées, la population doit dépasser 3 090 individus pendant trois années consécutives[137] En réponse aux efforts de rétablissement, la population a augmenté régulièrement du milieu du XXe siècle jusqu'au début des années 2000, puis est restée relativement stable entre 2005 et 2014, juste en dessous de 3 000 individus. Une certaine contraction a été observée aux limites nord (désormais Pigeon Point) et sud de l'aire de répartition de la loutre de mer à la fin de cette période, liée de manière circonstancielle à une augmentation des morsures mortelles de requins, ce qui a soulevé des inquiétudes quant au fait que la population ait atteint un plateau[138]. Ce seuil a été franchi pour la première fois en 2016 avec une moyenne triennale de 3 272 individus[135]. Toutefois, un retrait de la liste (delisting) semble peu probable à court terme en raison d'un déclin brutal de 25 % enregistré lors du recensement du printemps 2017, faisant retomber la population à 2 688 individus[139].

    Mexique
    L'historienne Adele Ogden a décrit les loutres de mer comme étant particulièrement abondantes en « Basse-Californie » (l'actuelle péninsule de Basse-Californie), où « sept baies... étaient les centres principaux ». La limite la plus méridionale était Punta Morro Hermoso, à environ 35 km au sud de Punta Eugenia, un cap situé à l'extrémité sud-ouest de la Baie de Sebastián Vizcaíno, sur la côte ouest de la péninsule. Des loutres ont également été capturées dans les îles San Benito, Cedros et Isla Natividad au sein de la baie[107]. Au début des années 1900, les loutres de mer de Basse-Californie ont été exterminées par la chasse. Lors d'une étude en 1997, de petits nombres de loutres de mer, y compris des loutrons, ont été signalés par des pêcheurs locaux, mais les scientifiques n'ont pu confirmer ces témoignages[140].

    Cependant, des loutres mâles et femelles ont été confirmées par des scientifiques au large des côtes de la péninsule de Basse-Californie dans une étude de 2014 ; les auteurs émettent l'hypothèse que les loutres ont commencé à se disperser dans la région à partir de 2005. Ces loutres pourraient provenir de l'Île San Nicolas, située à 300 km de là, car des individus ont déjà été enregistrés parcourant des distances supérieures à 800 km. L'analyse génétique de la plupart de ces animaux correspondait à l'origine californienne (États-Unis), mais une loutre présentait un haplotype jamais rapporté auparavant, ce qui pourrait représenter un vestige de la population native originelle du Mexique[141].

    Écologie
    Régime alimentaire

    Cette femelle loutre a récolté des moules et des anatifes sur un pilier de quai et est en train de les consommer.
    Les besoins énergétiques élevés du métabolisme de la loutre de mer l'obligent à consommer au moins 20 % de son poids corporel par jour[46]. La nage en surface et la recherche de nourriture sont des facteurs majeurs de leur dépense énergétique élevée, en raison de la traînée à la surface de l'eau lors de la nage et de la perte de chaleur corporelle lors des plongées profondes[142],[46]. Les muscles de la loutre de mer sont spécialement adaptés pour générer de la chaleur sans activité physique[143].

    La loutre de mer est un superprédateur qui consomme plus de 100 espèces de proies[144],[145]. Dans la majeure partie de son aire de répartition, son régime se compose presque exclusivement d'invertébrés marins benthiques, notamment des oursins (tels que Strongylocentrotus franciscanus et S. purpuratus), des étoiles de mer (Pisaster ochraceus), des concombres de mer, des vers marins, des crustacés, une variété de mollusques tels que les chitons (comme Katharina tunicata), des escargots comme les ormeaux et les patelles (comme Diodora aspera), et des bivalves tels que les palourdes, les moules (comme Mytilus edulis) et les pétoncles (comme Crassadoma gigantea)[144],[146]. Ses proies varient en taille, allant de minuscules patelles et crabes jusqu'aux pieuvres géantes[144]. Lorsque les proies sont présentes en plusieurs tailles, les loutres ont tendance à sélectionner les plus gros spécimens. En Californie, on a remarqué qu'elles ignoraient les palourdes de Pismo de moins de 7,5 cm de large[147].

    Dans quelques zones septentrionales, elles consomment également du poisson. Des études menées sur l'île d'Amchitka dans les années 1960, où la population avait atteint sa capacité de charge, ont montré que 50 % de la nourriture trouvée dans les estomacs était du poisson[148]. Il s'agissait généralement d'espèces de fond, sédentaires ou lentes, comme Hemilepidotus hemilepidotus et les poissons de la famille des Tetraodontidae[148]. Cependant, au sud de l'Alaska, le poisson est une part négligeable de leur régime alimentaire[15],[149]. Contrairement aux idées reçues, elles mangent rarement des étoiles de mer, et le varech consommé traverse apparemment le système digestif sans être digéré[150]. Les loutres s'attaquent occasionnellement aux oiseaux marins. En Californie, les espèces les plus touchées sont les grèbes élégants, bien que des cormorans, des goélands, des plongeons huards et des macreuses à front blanc soient aussi consommés[151].

    Espèce clé de voûte

    Les loutres de mer régulent les populations d'herbivores, garantissant une couverture suffisante de varech dans les forêts de varech.
    Les loutres de mer sont un exemple classique d'espèce clé de voûte ; leur présence affecte l'écosystème plus profondément que ne le suggèrent leur taille et leur nombre. Elles régulent les populations de certains herbivores benthiques, en particulier les oursins. Les oursins broutent la base des tiges de varech, ce qui provoque la dérive et la mort de l'algue. La perte de l'habitat et des nutriments fournis par les forêts de varech entraîne des effets en cascade profonds sur l'écosystème marin. Les zones du Pacifique Nord sans loutres se transforment souvent en « landes d'oursins », riches en oursins mais dépourvues de varech[27]. Les forêts de varech séquestrent le CO2 atmosphérique par photosynthèse ; ainsi, les loutres aident à atténuer les effets du changement climatique par leur influence trophique[152].

    La réintroduction des loutres en Colombie-Britannique a conduit à une amélioration spectaculaire de la santé des écosystèmes côtiers[153]. Des changements similaires ont été observés lors du rétablissement des populations aux Aléoutiennes, aux îles du Commandeur et sur la côte de Big Sur en Californie[154]. Elles affectent également les écosystèmes rocheux dominés par les moules en les retirant des rochers, ce qui libère de l'espace pour d'autres espèces et augmente la biodiversité[154] [].

    Des études récentes ont découvert d'autres bénéfices : en creusant pour trouver leurs proies, les loutres stimulent la croissance des herbiers marins et augmentent la diversité génétique des prairies de zostères, les rendant plus résilientes face aux tempêtes et à la montée du niveau de la mer[155]. En contrôlant les populations de crabes, elles réduisent également l'érosion côtière[156]. Elles limitent aussi la propagation d'espèces invasives destructrices comme le crabe vert européen[157].

    Prédateurs
    Les principaux prédateurs mammifères sont les orques. Les otaries et les pygargues à tête blanche peuvent s'attaquer aux petits[81]. Sur terre, les jeunes peuvent être attaqués par des ours et des coyotes. En Californie, le Grand requin blanc est le prédateur principal[158], bien qu'il s'agisse souvent d'une confusion avec des phoques (ils ne consomment généralement pas la loutre après l'avoir mordue)[159]. Dans le Parc national de Katmai, des loups gris ont été observés chassant et tuant des loutres de mer[160].

    Le ruissellement urbain transportant des excréments de chats vers l'océan propage Toxoplasma gondii, un parasite des félidés qui tue les loutres. Des infections par Sarcocystis neurona sont également associées à l'activité humaine. Selon l'USGS, les loutres de l'État de Washington ont été infectées par le virus de la grippe H1N1, suggérant qu'elles pourraient être un nouvel hôte animal pour les virus de l'influenza[161].

    L’Énhydre et l’Homme
    Menaces et conservation
    Traite pour la fourrure

    Des hommes Aléoutes à Unalaska en 1896 utilisant des équipements de kayak et des vêtements imperméables pour chasser la loutre de mer.
    La loutre de mer possède la fourrure la plus épaisse de tous les mammifères, ce qui en fait une cible privilégiée pour de nombreux chasseurs. Les preuves archéologiques indiquent que, pendant des millénaires, les peuples autochtones ont chassé la loutre de mer pour sa nourriture et sa fourrure. La chasse à grande échelle, s'inscrivant dans la Traite de la fourrure maritime, qui allait finalement causer la mort d'environ un million de loutres de mer, a débuté au XVIIIe siècle lorsque des chasseurs et des commerçants ont commencé à arriver du monde entier pour répondre à la demande étrangère de peaux de loutre, qui étaient l'un des types de fourrure les plus précieux au monde[12].

    Au début du XVIIIe siècle, les Russes ont commencé à chasser la loutre de mer dans les îles Kouriles[12] et les vendaient aux Chinois à Kiakhta. La Russie explorait également le Pacifique Nord à cette époque et envoya Vitus Béring pour cartographier la côte arctique et trouver des routes reliant la Sibérie à l'Amérique du Nord. En 1741, lors de son deuxième voyage dans le Pacifique Nord, Béring fit naufrage au large de l'Île Béring dans les Îles du Commandeur, où lui et une grande partie de son équipage périrent. Les survivants, dont le naturaliste Georg Steller, découvrirent des loutres de mer sur les plages de l'île et passèrent l'hiver à les chasser et à parier sur leurs peaux. Ils retournèrent en Sibérie après avoir tué près de 1 000 loutres de mer, obtenant des prix élevés pour leurs peaux[162]. C'est ainsi que commença ce que l'on appelle parfois la « Grande Chasse », qui allait se poursuivre pendant encore cent ans. Les Russes trouvèrent la loutre de mer bien plus précieuse que les peaux de zibeline qui avaient motivé et financé la majeure partie de leur expansion à travers la Sibérie. Si les peaux de loutre rapportées par les survivants de Béring avaient été vendues aux prix de Kiakhta, elles auraient remboursé un dixième du coût total de l'expédition de Béring[163].


    Ventes de peaux (en milliers) sur le marché de la fourrure de Londres – le déclin commençant dans les années 1880 reflète l'amenuisement des populations de loutres de mer[164].
    Les expéditions russes de chasse à la fourrure ont rapidement épuisé les populations de loutres de mer dans les îles du Commandeur et, dès 1745, elles ont commencé à se déplacer vers les îles Aléoutiennes. Les Russes commerçaient initialement avec les habitants Aléoutes pour les peaux de loutre, mais ils ont plus tard réduit les Aléoutes en esclavage, prenant femmes et enfants en otages et torturant ou tuant les hommes pour les forcer à chasser. De nombreux Aléoutes furent assassinés par les Russes ou périrent de maladies introduites par les chasseurs[165]. La population aléoute fut réduite, selon les propres estimations des Russes, de 20 000 à 2 000 individus[166]. Dans les années 1760, les Russes atteignirent l'Alaska. En 1799, le Tsar Paul Ier consolida les compagnies de chasse rivales au sein de la Compagnie russe d'Amérique, lui octroyant une charte impériale, une protection et le monopole des droits commerciaux et des acquisitions territoriales. Sous Alexandre Ier, l'administration de la compagnie fut transférée à la Marine impériale en raison des rapports alarmants sur les abus contre les indigènes ; en 1818, les peuples autochtones de l'Alaska se virent accorder des droits civiques équivalents au statut de citadin dans l'Empire russe[167].

    D'autres nations se joignirent à la chasse plus au sud. Le long des côtes de ce qui est aujourd'hui le Mexique et la Californie, des explorateurs espagnols achetaient des peaux de loutre de mer aux Amérindiens pour les vendre en Asie[165]. En 1778, l'explorateur britannique James Cook atteignit l'Île de Vancouver et acheta des fourrures aux membres des Premières Nations. Lorsque le navire de Cook fit escale dans un port chinois, les peaux se vendirent rapidement à des prix élevés et furent bientôt connues sous le nom d'« or doux ». À mesure que la nouvelle se répandait, des Européens et des Nord-Américains affluèrent dans le Nord-Ouest Pacifique pour commercer la fourrure de loutre[168].

    La chasse russe s'étendit vers le sud, initiée par des capitaines de navires américains qui sous-traitaient des superviseurs russes et des chasseurs aléoutes[169] dans les actuels États de Washington, de l'Oregon et de Californie. Entre 1803 et 1846, 72 navires américains participèrent à la chasse à la loutre en Californie, récoltant environ 40 000 peaux et queues, contre seulement 13 navires de la Compagnie russe d'Amérique, qui déclara 5 696 peaux entre 1806 et 1846[170] . En 1812, les Russes fondèrent une colonie agricole à ce qui est aujourd'hui Fort Ross dans le nord de la Californie, comme quartier général méridional[168].

    Finalement, les populations de loutres de mer devinrent si rares que la chasse commerciale ne fut plus viable. Elle cessa dans les îles Aléoutiennes dès 1808, par mesure de conservation imposée par la Compagnie russe d'Amérique. D'autres restrictions furent ordonnées par la compagnie en 1834[171]. Lorsque la Russie vendit l'Alaska aux États-Unis en 1867, la population de l'Alaska était remontée à plus de 100 000 individus, mais les Américains reprirent la chasse et exterminèrent à nouveau rapidement la loutre de mer localement[172]. Les prix grimpèrent à mesure que l'espèce se raréfiait. Dans les années 1880, une peau rapportait entre 105 $ et 165 $ sur le marché de Londres, mais en 1903, une peau pouvait valoir jusqu'à 1 125 $[92]. En 1911, la Russie, le Japon, la Grande-Bretagne (pour le Canada) et les États-Unis signèrent le Traité sur la préservation et la protection des phoques à fourrure, imposant un moratoire sur la récolte des loutres de mer[173]. Il restait si peu d'individus, peut-être seulement 1 000 à 2 000 à l'état sauvage, que beaucoup pensaient que l'espèce allait s'éteindre[15]. La chasse excessive des loutres de mer près des îles du Commandeur a probablement contribué à l'extinction de la Rhytine de Steller[174].

    Rétablissement et conservation

    À la suite de la marée noire de l'Exxon Valdez en mars 1989, d'épaisses nappes de pétrole ont recouvert de vastes zones du Détroit du Prince-William.
    Au cours du XXe siècle, les effectifs de loutres de mer ont rebondi dans environ deux tiers de leur aire de répartition historique, un rétablissement considéré comme l'un des plus grands succès de la conservation marine[175]. Cependant, l'UICN classe toujours la loutre de mer comme une espèce en danger, et décrit les menaces significatives pesant sur elle comme étant la pollution pétrolière, la prédation par les orques, le braconnage et les conflits avec les pêcheries — les loutres de mer peuvent se noyer si elles s'emmêlent dans des engins de pêche[176]. La chasse à la loutre de mer n'est plus légale, à l'exception de récoltes limitées par les peuples autochtones aux États-Unis[177]. Le braconnage était une préoccupation sérieuse dans l'Extrême-Orient russe immédiatement après l'effondrement de l'Union soviétique en 1991 ; cependant, il a considérablement diminué avec le renforcement de l'application des lois et l'amélioration des conditions économiques[118].

    La menace la plus importante pour les loutres de mer est la marée noire[81], à laquelle elles sont particulièrement vulnérables car elles comptent sur leur fourrure pour rester au chaud. Lorsque leur pelage est imprégné de pétrole, il perd sa capacité à emprisonner l'air, et les animaux peuvent rapidement mourir d'hypothermie[81]. Le foie, les reins et les poumons des loutres sont également endommagés lorsqu'elles inhalent du pétrole ou en ingèrent lors du toilettage[81]. La marée noire de l'Exxon Valdez du 24 mars 1989 a tué des milliers de loutres de mer dans le Détroit du Prince-William, et en 2006, le pétrole persistant dans la zone continuait d'affecter la population[178]. Décrivant la sympathie du public pour les loutres de mer née de la couverture médiatique de l'événement, un porte-parole du U.S. Fish and Wildlife Service a écrit[15] :

    « En tant que témoin innocent, joueur et photogénique, la loutre de mer a incarné le rôle de la victime... des loutres de mer mignonnes et folâtres soudainement en détresse, mazoutées, effrayées et mourantes, dans une bataille perdue d'avance contre le pétrole. »

    Les petites étendues géographiques des populations de loutres de mer en Californie, à Washington et en Colombie-Britannique signifient qu'une seule marée noire majeure pourrait être catastrophique pour cet État ou cette province[15],[71],[77]. La prévention des marées noires et la préparation au sauvetage des loutres en cas de sinistre sont des axes majeurs des efforts de conservation. Augmenter la taille et l'aire de répartition des populations réduirait également le risque qu'une marée noire n'anéantisse une population entière[15]. Cependant, en raison de la réputation de l'espèce de décimer les ressources en crustacés, les défenseurs de la pêche commerciale et récréative se sont souvent opposés à l'extension de son aire de répartition, et il y a même eu des cas de pêcheurs et d'autres personnes les tuant illégalement[179].

    Avec une population initiale de seulement cinquante individus après la traite des fourrures, la faible diversité génétique a produit un goulot d'étranglement évolutif. Les contraintes récentes ont conduit à une faible diversité génomique avec de nombreux indices de consanguinité[38]. Cela a favorisé des mutations faux-sens délétères qui peuvent freiner la croissance démographique. Bien que le renforcement de la diversité génétique par des programmes de reproduction soit coûteux, il est essentiel pour stabiliser la population. Cette méthode a déjà été utilisée pour le guépard, et des programmes de reproduction en captivité via des organisations telles que le Monterey Bay Aquarium et le Marine Mammal Center rendent possible le retour aux effectifs antérieurs à la traite des fourrures. En Californie, la population est remontée à environ 3 000 individus[180]. Si ce chiffre reste bien inférieur aux niveaux historiques, il représente une amélioration massive. À l'inverse, les loutres de mer du Nord ont retrouvé leurs effectifs historiques, vivant tout au long de la côte de l'Alaska, de Ketchikan à l'est jusqu'à l'île d'Attu à l'ouest. Les techniques modernes incluent le croisement entre les populations du Nord et du Sud pour accroître la diversité génétique. De plus, la loi sur la protection des mammifères marins (Marine Mammal Protection Act) des années 1970 a rendu leur chasse strictement illégale aux États-Unis.

    Dans les îles Aléoutiennes, une disparition massive et inattendue a eu lieu ces dernières décennies. De 55 000 à 100 000 loutres dans les années 1980, la population est tombée à environ 6 000 individus en 2000[181]. L'hypothèse la plus acceptée, bien que controversée, est que les orques ont commencé à consommer les loutres, bien qu'il n'y ait pas de preuve directe d'une prédation à grande échelle[124].

    La Californie est une autre zone de préoccupation, où le rétablissement a commencé à stagner ou décliner à la fin des années 1990[182]. Des taux de mortalité inhabituellement élevés chez les adultes, en particulier les femelles, ont été signalés. En 2017, une baisse de 3 % de la population californienne a été enregistrée. Les nécropsies indiquent que les maladies, notamment la toxoplasmose (Toxoplasma gondii) et les infections par des parasites acanthocéphales, sont des causes majeures de mortalité. Le parasite Toxoplasma gondii est porté par les chats sauvages et domestiques et peut être transmis par les déjections rincées dans l'océan via les systèmes d'égouts[183].


    Couple de loutres de mer au large de l'État de Washington, dans le Sanctuaire marin national de la côte olympique.
    L'habitat de la loutre de mer est préservé par plusieurs aires marines protégées aux États-Unis, en Russie et au Canada. Dans ces zones, les activités polluantes comme le rejet de déchets et le forage pétrolier sont généralement interdites. On estime que 1 200 loutres vivent dans le Sanctuaire marin national de la baie de Monterey et plus de 500 dans le Sanctuaire marin national de la côte olympique.

    État actuel de la conservation
    Les loutres de mer, étant reconnues comme une espèce clé de voûte, nécessitent des efforts de protection pour éviter leur mise en danger par une « exploitation humaine non réglementée »[184]. Cette espèce est de plus en plus impactée par les marées noires majeures et la dégradation de l'environnement causée par la surpêche et l'enchevêtrement dans les engins de pêche[184]. Des efforts législatifs ont été entrepris depuis le début du XXe siècle : le Traité sur la préservation et la protection des phoques à fourrure de 1911, l'Endangered Species Act de 1973 aux États-Unis, les classements de l'Union internationale pour la conservation de la nature (UICN), la Convention sur le commerce international des espèces de faune et de flore sauvages menacées d'extinction (CITES ; également connue sous le nom de Convention de Washington) et la loi américaine sur la protection des mammifères marins de 1972 (Marine Mammal Protection Act). D'autres efforts de conservation passent par la réintroduction et les parcs zoologiques.

    La Semaine de sensibilisation à la loutre de mer (Sea Otter Awareness Week) se tient chaque année pendant la dernière semaine complète de septembre. Des zoos, des aquariums et d'autres institutions éducatives organisent des événements soulignant l'importance écologique des loutres de mer et les défis auxquels leur conservation est confrontée. Elle est organisée et parrainée par Defenders of Wildlife, le Monterey Bay Aquarium, le California Department of Parks and Recreation, Sea Otter Savvy et l'Elakha Alliance[185],[186].

    Rôles dans la culture
    Impact économique
    Certaines des proies préférées de la loutre de mer, en particulier les ormeaux, les palourdes et les crabes, sont également des sources de nourriture pour l'homme. Dans certaines régions, les déclins massifs des récoltes de coquillages et crustacés ont été imputés à la loutre de mer, et un débat public intense a eu lieu sur la manière de gérer la compétition pour les produits de la mer entre les loutres et les humains[187].

    Le débat est complexe car les loutres de mer ont parfois été tenues pour responsables de déclins de stocks qui étaient plus probablement causés par la surpêche, les maladies, la pollution et l'activité sismique[77],[188]. Des déclins de coquillages se sont également produits dans de nombreuses parties de la côte pacifique de l'Amérique du Nord où il n'y a pas de loutres de mer, et les défenseurs de l'environnement notent parfois que l'existence de grandes concentrations de coquillages sur la côte est un développement récent résultant de la quasi-extirpation de la loutre de mer par la traite des fourrures[188]. Bien que de nombreux facteurs affectent les stocks, la prédation par les loutres peut épuiser une pêcherie au point qu'elle ne soit plus commercialement viable[187]. Les scientifiques s'accordent sur le fait que les loutres de mer et les pêcheries d'ormeaux ne peuvent coexister dans la même zone[187], et il en est probablement de même pour certains autres types de coquillages[181].

    De nombreux aspects de l'interaction entre les loutres de mer et l'économie humaine ne sont pas ressentis immédiatement. Les loutres de mer sont créditées de contribuer à l'industrie de la récolte du varech via leur rôle bien connu de régulation des populations d'oursins ; le varech est utilisé dans la production de divers produits alimentaires et pharmaceutiques[189]. Bien que les plongeurs humains récoltent les oursins rouges à la fois pour se nourrir et pour protéger le varech, les loutres de mer chassent davantage d'espèces d'oursins et sont plus systématiquement efficaces pour contrôler ces populations[190]. E. lutris est un prédateur régulateur du crabe royal (Paralithodes camtschaticus) dans la mer de Béring, qui serait autrement hors de contrôle comme il l'est dans son aire de répartition envahissante, la Mer de Barents[191]. (Les loutres de Barents, Lutra lutra, occupent la même niche écologique et sont donc censées aider à les contrôler, mais cela n'a pas été étudié). Les loutres de mer sont également connues pour contrôler les populations d'espèces envahissantes très destructrices comme le crabe vert européen, que le gouvernement américain a dépensé des millions à essayer d'éradiquer, sans grand succès. La santé de l'écosystème de la forêt de varech est cruciale pour nourrir les populations de poissons, y compris les espèces de poissons d'importance commerciale[189].

    Dans certaines régions, les loutres de mer sont des attractions touristiques populaires, attirant des visiteurs dans les hôtels locaux, les restaurants et pour des expéditions d'observation[189]. Selon une étude, les revenus du tourisme lié à la loutre de mer ont été projetés à environ 41,5 millions de dollars canadiens par an (30,5 millions de dollars américains). Une autre étude de l'île de Vancouver a révélé que les loutres de mer sont la deuxième attraction la plus populaire pour les circuits d'observation de la faune, juste derrière l'observation des baleines. Les auteurs ont également noté des avantages similaires pour l'industrie du tourisme dans le sud-est de l'Alaska. En Californie, il a été constaté que les ménages étaient systématiquement prêts à payer plus pour avoir l'option de voir des loutres de mer au large des côtes, et plus encore simplement pour savoir qu'elles existent à proximité du littoral[192].

    Rôles dans les cultures humaines
    Pour de nombreuses cultures maritimes indigènes du Pacifique Nord, en particulier les Aïnous des îles Kouriles, les Koriaks et les Itelmènes du Kamtchatka, les Aléoutes des îles Aléoutiennes, les Haïdas de Haïda Gwaïi[193] et une multitude de tribus de la côte pacifique de l'Amérique du Nord, la loutre de mer a joué un rôle important en tant que ressource culturelle et matérielle. Ces cultures, dont beaucoup possèdent de fortes traditions animistes riches en légendes où de nombreux aspects du monde naturel sont associés à des esprits, considéraient la loutre de mer comme un proche parent de l'homme. Les Nuu-chah-nulth, les Haïdas et d'autres Premières Nations de la côte de la Colombie-Britannique utilisaient les peaux chaudes et luxueuses comme apparats pour les chefs. Les peaux de loutre de mer étaient offertes lors de potlatchs pour marquer les cérémonies de passage à l'âge adulte, les mariages et les funérailles[194]. Les Aléoutes sculptaient les os de loutre de mer pour en faire des ornements ou des pièces de jeux, et utilisaient le baculum de loutre réduit en poudre comme remède contre la fièvre[195].

    Certains contes populaires aïnous présentent la loutre de mer comme un messager occasionnel entre les humains et le créateur[196]. La loutre de mer est une figure récurrente du folklore aïnou. Une épopée majeure de cette culture, le Kutune Shirka, raconte l'histoire de guerres et de luttes autour d'une loutre de mer dorée. Des versions d'une légende aléoute répandue racontent que des amants ou des femmes désespérées se jettent à la mer et deviennent de ces animaux[197]. Un autre conte populaire aïnu originaire d'Urashibetsu (Abashiri, Hokkaido), mentionne des récits selon lesquels de monstrueuses enhydres capables de se métamorphoser en humains. Elles s'introduisent alors dans les foyers où résident de belles jeunes filles dans le but de les tuer et d'en faire leurs épouses[198].

    Ces récits sont associés aux nombreux traits comportementaux de la loutre proches de l'Homme, notamment son espièglerie apparente, les liens étroits entre la mère et son petit et l'utilisation d'outils, ce qui prête volontiers à l'anthropomorphisme[14]. Le début de l'exploitation commerciale a eu un impact profond sur les populations humaines autant qu'animales. Les Aïnous et les Aléoutes ont été déplacés ou ont vu leur nombre chuter, tandis que les tribus côtières d'Amérique du Nord, où la loutre est de toute façon fortement décimée, ne dépendent plus aussi intimement des mammifères marins pour leur survie.

    Depuis le milieu des années 1970, la beauté et le charisme de l'espèce ont acquis une large reconnaissance, et la loutre de mer est devenue une icône de la conservation de l'environnement[182]. Son visage rond et expressif ainsi que son corps doux et poilu sont représentés sur une grande variété de souvenirs, cartes postales, vêtements et peluches[199].

    Au cours des dernières décennies, les loutres de mer ont connu un véritable boom de popularité au Japon et apparaissent dans un large éventail de médias. Une loutre de mer est le protagoniste du manga Bonobono de Mikio Igarashi, et une autre fait partie des personnages principaux du célèbre web manga Chiikawa. La loutre de mer a également fait son apparition dans la littérature moderniste, comme dans le roman de Makoto Furukawa, La Maison de la loutre de mer (ラッコの家), qui traite d'une femme sénile s'imaginant se transformer en énhydre, et qui a été nommé pour le prestigieux Prix Akutagawa en 2019[200]. Le Pokémon Moustillon et ses évolutions tirent leur conception graphiques des énhydres[201].

    Dans la littérature américaine, la nouvelle « Like Young » de Theodore Sturgeon met en scène un récit où l'humanité s'éteint à la suite d'une épidémie et où les derniers survivants décident de transmettre leurs connaissances scientifiques aux loutres de mer[202].

    En captivité
    Une loutre de mer en captivité au Japon, 2015.
    Les loutres de mer s'adaptent bien à la captivité et sont présentes dans plus de 40 aquariums publics et zoos[203]. L'Aquarium de Seattle est devenu la première institution à élever des loutres de mer de la conception à l'âge adulte avec la naissance de Tichuk en 1979, suivie de trois autres petits au début des années 1980[204]. En 2007, une vidéo YouTube montrant deux loutres de mer se tenant la patte a attiré 1,5 million de spectateurs en deux semaines, et comptait plus de 22 millions de vues en juillet 2022[205]. Filmée cinq ans plus tôt à l'Aquarium de Vancouver, c'était à l'époque la vidéo d'animaux la plus populaire de YouTube. La loutre au pelage plus clair dans la vidéo est Nyac, une survivante de la marée noire de l'Exxon Valdez de 1989[206]. Nyac est morte en septembre 2008 à l'âge de 20 ans. Milo, la loutre plus sombre, est décédée d'un lymphome en janvier 2012.

    D'autres loutres de mer de l'Aquarium de Vancouver sont également devenues virales. Pendant la Pandémie de Covid-19, la diffusion en direct de Joey, un loutron sauvé au Marine Mammal Rescue Center, a attiré des millions de spectateurs du monde entier sur YouTube et Twitch. De nombreux spectateurs ont affirmé que ce direct les avait aidés à faire face à l'anxiété et à la dépression causées par les confinements liés à la pandémie[207]. En juin 2024, une vidéo d'un autre loutron sauvé, Tofino, a reçu plus de 120 000 000 de vues et 5 000 000 de mentions « j'aime » sur Instagram[208].

    Depuis 2019, le streamer Douglas Wreden, plus connu sous le nom de DougDoug, organise des diffusions caritatives au profit du Monterey Bay Aquarium pour célébrer l'anniversaire de Rosa, une loutre de mer résidente[209]. En 2024, DougDoug et sa communauté ont récolté plus de 1 000 000 $ au nom de Rosa[210].
    ```

    lines := strings.split(long_text, "\n", context.temp_allocator)
    long_text_box: ^UiBox

    ui_push_pref_width({ kind = .Percent_Of_Parent, value = 1 })
    ui_push_pref_height({ kind = .Percent_Of_Parent, strictness = 0, value = 1 })
    ui_column_begin({.Draw_Background, .Draw_Border, .View_Scroll_X, .View_Scroll_Y, .Clip}, padding = { kind = .Pixels, value = 1, strictness = 1 })
        ui_row_begin()
            ui_spacer({ kind = .Pixels, value = 15, strictness = 1 })
            ui_column_begin(padding = { kind = .Pixels, value = 15, strictness = 1 })
                long_text_box = ui_column_begin({.View_Scroll_Y, .Clip}, "long_text")
                ui_column_end()
            ui_column_end()
            ui_spacer({ kind = .Pixels, value = 15, strictness = 1 })

            ui_push_background_color({ 0.2, 0.2, 0.2, 1 })
            ui_push_text_color({ 0.5, 0.4, 0.5, 1 })
            ui_scroll_bar(long_text_box)
            ui_pop_text_color()
            ui_pop_background_color()
            ui_spacer({ kind = .Pixels, value = 1, strictness = 1 })

            ui_push_parent(long_text_box)
                signal := ui_signal(long_text_box)
                rect   := signal.clip_rect
                offset := max(0, min(long_text_box.scroll.offset[1], long_text_box.scroll.target[1]))
                height := rect.max[1] - rect.min[1]
                if height == 0 do height = frame.resolution[1]
                height += abs(long_text_box.scroll.target[1] - long_text_box.scroll.offset[1])
                line_height := ui_line_height()
                total_lines := f32(len(lines))
                line_start := math.floor(offset / line_height)
                line_count := min(total_lines - line_start, math.ceil(height / line_height) + 1)

                ui_spacer({ kind = .Pixels, value = line_start * line_height, strictness = 1 })
                ui_push_pref_width({ kind = .Text_Content, strictness = 1 })
                ui_push_pref_height({ kind = .Text_Content, strictness = 1 })
                for line in lines[int(line_start):][:int(line_count)] {
                    ui_label(line)
                }
                ui_pop_pref_height()
                ui_pop_pref_width()
                ui_spacer({ kind = .Pixels, value = (total_lines - line_start - line_count) * line_height, strictness = 1 })
            ui_pop_parent()
        ui_row_end()
    ui_column_end()
    ui_pop_pref_width()
    ui_pop_pref_height()


    ui_pop_font_face()
    ui_end()
}

render_job :: proc(data: rawptr, index: i32) {
    frame := (^FrameContext)(data)
    gfx_render(frame)
    free_all(frame.allocator)
}

entry :: proc(window: WindowHandle) {
    job_init()
    defer job_shutdown()

    gpu_init()
    defer gpu_shutdown()

    swapchain := gpu_equip_window(window)
    defer gpu_unequip_window(swapchain)

    gfx_init()
    defer gfx_shutdown()

    app: AppContext
    app.face = gfx_font_open("Quicksand-Regular.ttf")

    frame_contexts: [2]FrameContext
    for &frame in frame_contexts {
        if err := virtual.arena_init_growing(&frame.arena); err != nil {
            panic("failed to init the frame arena")
        }
        frame.allocator = virtual.arena_allocator(&frame.arena)
        frame.swapchain = swapchain
        frame.cube_color = { 1.0, 0.35, 0.2, 1 }
    }

    start_tick := time.tick_now()
    last_tick := start_tick
    initial_x, initial_y := os_mouse_position(window)

    app.cursor.x, app.cursor.y = f32(initial_x), f32(initial_y)

    loop: for frame_index : i64 = 0;; frame_index += 1 {
        frame := &frame_contexts[frame_index % len(frame_contexts)]
        free_all(frame.allocator)
        frame.index = frame_index

        if app.async_rendering {
            gpu_swapchain_wait(frame.swapchain)
        }

        frame.os_events = os_poll_events()
        now := time.tick_now()
        frame.dt = f32(time.duration_seconds(time.tick_diff(last_tick, now)))
        frame.time = f32(time.duration_seconds(time.tick_diff(start_tick, now)))
        last_tick = now
        window_width, window_height := os_window_size(window)
        frame.resolution.x, frame.resolution.y = f32(max(1, window_width)), f32(max(1, window_height))
        frame.window = window

        update(&app, frame)
        if app.done do break

        if app.render_counter != nil {
            wait_and_release_counter(app.render_counter)
            app.render_counter = nil
        }

        frame.ui = ui_layout()

        if app.async_rendering {
            app.render_counter = job_schedule(.High, render_job, frame)
        } else {
            render_job(frame, 0)
            gpu_queue_wait(.Direct)
        }

        free_all(context.temp_allocator)
    }

    if app.render_counter != nil {
        wait_and_release_counter(app.render_counter)
    }
}
