import Foundation
import Observation

/// A single quirky, on-brand loading message.
///
/// `text` doubles as the SwiftUI localization key: the view renders it through
/// `LocalizedStringKey(message.text)`, so the English copy here is shown as-is
/// until a string catalog provides a translation. `accessibilityText` lets a
/// message read differently for VoiceOver (e.g. spelling out an ellipsis as a
/// pause) without changing the on-screen wording.
public struct LoadingMessage: Sendable, Equatable, Identifiable {
    public let id: String
    public let text: String
    public let accessibilityText: String?

    public init(id: String, text: String, accessibilityText: String? = nil) {
        self.id = id
        self.text = text
        self.accessibilityText = accessibilityText
    }

    /// What VoiceOver should speak for this message — the explicit override if
    /// provided, otherwise the visible text.
    public var spokenText: String { accessibilityText ?? text }
}

public extension LoadingMessage {
    /// The default playful, tasteful message set. Tasteful and brand-safe; easy
    /// to extend (append more) and localize (each `text` is a catalog key).
    static let playfulDefaults: [LoadingMessage] = [
        LoadingMessage(id: "wrangling-pixels", text: "Still wrangling the pixels…"),
        LoadingMessage(id: "negotiating-server", text: "Bribing the server with snacks…"),
        LoadingMessage(id: "buttering-popcorn", text: "Buttering the popcorn…"),
        LoadingMessage(id: "dimming-lights", text: "Dimming the lights…"),
        LoadingMessage(id: "untangling-cables", text: "Untangling the cables…"),
        LoadingMessage(id: "summoning-frames", text: "Summoning the frames…"),
        LoadingMessage(id: "warming-projector", text: "Warming up the projector…"),
        LoadingMessage(id: "cat-on-remote", text: "Waiting for the cat to move off the remote…"),
        LoadingMessage(id: "warming-tubes", text: "Warming up the tubes…"),
        LoadingMessage(id: "finding-remote", text: "Searching the couch cushions…"),
        LoadingMessage(id: "shooing-dog", text: "Shooing the dog off the couch…"),
        LoadingMessage(id: "buffering-gremlins", text: "Chasing away the buffering gremlins…"),
        LoadingMessage(id: "server-hamsters", text: "Feeding the hamsters that power the servers…"),
        LoadingMessage(id: "polishing-pixels", text: "Polishing the pixels…"),
        LoadingMessage(id: "herding-mice", text: "Herding the mice…"),
        LoadingMessage(id: "coaxing-frames", text: "Coaxing the frames into line…"),
        LoadingMessage(id: "bribing-buffer-wheel", text: "Bribing the buffering wheel…"),
        LoadingMessage(id: "convincing-wifi", text: "Convincing the Wi‑Fi to behave…"),
        LoadingMessage(id: "tuning-antenna", text: "Tuning the antenna…"),
        LoadingMessage(id: "untwisting-hdmi", text: "Untwisting the HDMI cable…"),
        LoadingMessage(id: "blowing-dust", text: "Blowing dust off the cartridge…"),
        LoadingMessage(id: "finding-good-seat", text: "Finding a good seat…"),
        LoadingMessage(id: "rolling-red-carpet", text: "Rolling out the red carpet…"),
        LoadingMessage(id: "handing-3d-glasses", text: "Handing out the 3D glasses…"),
        LoadingMessage(id: "salting-popcorn", text: "Salting the popcorn…"),
        LoadingMessage(id: "focusing-lens", text: "Focusing the lens…"),
        LoadingMessage(id: "threading-film", text: "Threading the film…"),
        LoadingMessage(id: "lowering-screen", text: "Lowering the big screen…"),
        LoadingMessage(id: "fluffing-pillows", text: "Fluffing the pillows…"),
        LoadingMessage(id: "grabbing-blanket", text: "Grabbing a blanket…"),
        LoadingMessage(id: "adjusting-recliner", text: "Adjusting the recliner…"),
        LoadingMessage(id: "waiting-popcorn-pop", text: "Waiting for the popcorn to pop…"),
        LoadingMessage(id: "stretching-marathon", text: "Stretching before the marathon…"),
        LoadingMessage(id: "pretending-busy", text: "Pretending to look busy…"),
        LoadingMessage(id: "making-it-look-easy", text: "Making it look easy…"),
        LoadingMessage(id: "flux-capacitor", text: "Warming up the flux capacitor…"),
        LoadingMessage(id: "hyperdrive", text: "Spinning up the hyperdrive…"),
        LoadingMessage(id: "consulting-force", text: "Consulting the Force…"),
        LoadingMessage(id: "second-breakfast", text: "Waiting for a second breakfast…"),
        LoadingMessage(id: "reversing-polarity", text: "Reversing the polarity…"),
        LoadingMessage(id: "build-it-they-come", text: "Building it so they will come…"),
        LoadingMessage(id: "waiting-owls", text: "Waiting for the owls…"),
        LoadingMessage(id: "winter-loading", text: "Winter is loading…"),
        LoadingMessage(id: "charging-lightsaber", text: "Charging the lightsaber…"),
        LoadingMessage(id: "bat-signal", text: "Waiting for the Bat‑Signal…"),
        LoadingMessage(id: "assembling-team", text: "Assembling the team…"),
        LoadingMessage(id: "waking-kraken", text: "Waking the kraken…"),
        LoadingMessage(id: "polishing-delorean", text: "Polishing the DeLorean…"),
        LoadingMessage(id: "sonic-screwdriver", text: "Calibrating the sonic screwdriver…"),
        LoadingMessage(id: "sentient-toaster", text: "Convincing the toaster it's not sentient…"),
        LoadingMessage(id: "very-good-dog", text: "Petting the very good dog…"),
        LoadingMessage(id: "tumbleweed", text: "Chasing a tumbleweed off the set…"),
        LoadingMessage(id: "raccoons-booth", text: "Rounding up the raccoons in the projector booth…"),
        LoadingMessage(id: "asking-hal-open-pod", text: "Asking HAL to open the pod bay doors…"),
        LoadingMessage(id: "deciding-red-pill-or", text: "Deciding: red pill, or blue pill…"),
        LoadingMessage(id: "requesting-more-power-scotty", text: "Requesting more power from Scotty…"),
        LoadingMessage(id: "waiting-groot-finish-growing", text: "Waiting for Groot to finish growing…"),
        LoadingMessage(id: "letting-e-t-finish", text: "Letting E.T. finish phoning home…"),
        LoadingMessage(id: "waiting-spinning-top-topple", text: "Waiting for the spinning top to topple…"),
        LoadingMessage(id: "drifting-through-wormhole", text: "Drifting through the wormhole…"),
        LoadingMessage(id: "recharging-proton-packs", text: "Recharging the proton packs…"),
        LoadingMessage(id: "waiting-mission-tape-self", text: "Waiting for the mission tape to self-destruct…"),
        LoadingMessage(id: "dodging-giant-rolling-boulder", text: "Dodging the giant rolling boulder…"),
        LoadingMessage(id: "asking-q-right-gadget", text: "Asking Q for the right gadget…"),
        LoadingMessage(id: "avoiding-snakes-snakes", text: "Avoiding snakes. All the snakes…"),
        LoadingMessage(id: "requesting-flyby-tower-watching", text: "Requesting a flyby. The tower is watching…"),
        LoadingMessage(id: "sharpening-adamantium-claws", text: "Sharpening the adamantium claws…"),
        LoadingMessage(id: "giving-thanos-chance-reconsider", text: "Giving Thanos a chance to reconsider…"),
        LoadingMessage(id: "velociraptors-being-clever-again", text: "The velociraptors are being clever again…"),
        LoadingMessage(id: "making-sure-paddock-gates", text: "Making sure the paddock gates are holding…"),
        LoadingMessage(id: "ready-close", text: "Ready for the close-up…"),
        LoadingMessage(id: "following-yellow-brick-road", text: "Following the yellow brick road…"),
        LoadingMessage(id: "applying-smell-o-vision", text: "Applying the Smell-O-Vision filters…"),
        LoadingMessage(id: "checking-intermission-clock", text: "Checking the intermission clock…"),
        LoadingMessage(id: "waiting-curtains-part", text: "Waiting for the curtains to part…"),
        LoadingMessage(id: "practising-wilhelm-scream-case", text: "Practising the Wilhelm Scream…"),
        LoadingMessage(id: "foley-artist-knocked-something", text: "The Foley artist just knocked something over…"),
        LoadingMessage(id: "calling-stunt-double", text: "Calling in the stunt double…"),
        LoadingMessage(id: "continuity-team-needs-moment", text: "The continuity team needs a moment…"),
        LoadingMessage(id: "setting-martini-shot", text: "Setting up the martini shot…"),
        LoadingMessage(id: "working-if-s-groundhog", text: "Working out if it's Groundhog Day again…"),
        LoadingMessage(id: "s-merely-flesh-wound", text: "It's merely a flesh wound, apparently…"),
        LoadingMessage(id: "gathering-knights-who-say", text: "Gathering the knights who say Ni…"),
        LoadingMessage(id: "negotiating-pirates-tortuga", text: "Negotiating with the pirates of Tortuga…"),
        LoadingMessage(id: "saddling-donkey-journey", text: "Saddling up Donkey for the journey…"),
        LoadingMessage(id: "working-if-need-bigger", text: "Working out if we need a bigger boat…"),
        LoadingMessage(id: "convincing-sharks-fish-friends", text: "Convincing the sharks that fish are friends…"),
        LoadingMessage(id: "calculating-route-infinity-beyond", text: "Calculating the route to infinity and beyond…"),
        LoadingMessage(id: "consulting-edna-mode-about", text: "Consulting Edna Mode about the delay…"),
        LoadingMessage(id: "hakuna-matata-ing-moment", text: "Hakuna matata-ing for just a moment…"),
        LoadingMessage(id: "asking-gandalf-if-re", text: "Asking Gandalf if we're precisely on time…"),
        LoadingMessage(id: "untangling-marauder-s-map", text: "Untangling the Marauder's Map…"),
        LoadingMessage(id: "waiting-wardrobe-door-swing", text: "Waiting for the wardrobe door to swing open…"),
        LoadingMessage(id: "adjusting-rabbit-ears", text: "Adjusting the rabbit ears…"),
        LoadingMessage(id: "please-stand-by-regularly", text: "Please stand by for the regularly scheduled programme…"),
        LoadingMessage(id: "warming-color-bars", text: "Warming up the color bars…"),
        LoadingMessage(id: "flipping-through-tv-guide", text: "Flipping through the TV Guide…"),
        LoadingMessage(id: "checking-if-norm-bar", text: "Checking if Norm is at the bar…"),
        LoadingMessage(id: "figuring-if-were-break", text: "Figuring out if we were on a break…"),
        LoadingMessage(id: "could-any-slower", text: "Could this BE any slower?…"),
        LoadingMessage(id: "cueing-laugh-track", text: "Cueing the laugh track…"),
        LoadingMessage(id: "waiting-studio-audience-settle", text: "Waiting for the studio audience to settle down…"),
        LoadingMessage(id: "learning-something-important-about", text: "Learning something important about friendship…"),
        LoadingMessage(id: "waiting-very-special-episode", text: "Waiting for a very special episode…"),
        LoadingMessage(id: "like-sands-through-hourglass", text: "Like sands through the hourglass, so are these seconds…"),
        LoadingMessage(id: "checking-if-there-s", text: "Checking if there's any soup today…"),
        LoadingMessage(id: "locating-upside-down", text: "Locating the Upside Down…"),
        LoadingMessage(id: "translating-klingon-user-manual", text: "Translating the Klingon user manual…"),
        LoadingMessage(id: "making", text: "Making it so…"),
        LoadingMessage(id: "checking-network-cylons", text: "Checking the network for Cylons…"),
        LoadingMessage(id: "decrypting-truth-s-there", text: "Decrypting the truth that's out there…"),
        LoadingMessage(id: "sharpening-dragonglass", text: "Sharpening the dragonglass…"),
        LoadingMessage(id: "waiting-tardis-materialize", text: "Waiting for the TARDIS to materialize…"),
        LoadingMessage(id: "deciding-if-good-place", text: "Deciding if this is the Good Place…"),
        LoadingMessage(id: "rerouting-power-deflector-dish", text: "Rerouting power to the deflector dish…"),
        LoadingMessage(id: "outsmarting-average-load-time", text: "Outsmarting the average load time…"),
        LoadingMessage(id: "channelling-inner-shaggy", text: "Channelling our inner Shaggy…"),
        LoadingMessage(id: "waiting-acme-delivery", text: "Waiting for the Acme delivery…"),
        LoadingMessage(id: "getting-mystery-machine-ready", text: "Getting the Mystery Machine ready…"),
        LoadingMessage(id: "reticulating-cartoon-physics", text: "Reticulating cartoon physics…"),
        LoadingMessage(id: "consulting-great-gazoo", text: "Consulting the Great Gazoo…"),
        LoadingMessage(id: "preparing-rose-ceremony", text: "Preparing the rose ceremony…"),
        LoadingMessage(id: "waiting-tribal-council-verdict", text: "Waiting for the tribal council verdict…"),
        LoadingMessage(id: "spinning-big-wheel", text: "Spinning the big wheel…"),
        LoadingMessage(id: "consulting-judging-panel", text: "Consulting the judging panel…"),
        LoadingMessage(id: "revealing-what-s-behind", text: "Revealing what's behind door number two…"),
        LoadingMessage(id: "definitely-here-right-reasons", text: "Definitely here for the right reasons…"),
        LoadingMessage(id: "arranging-season-finale-cliffhanger", text: "Arranging the season finale cliffhanger…"),
        LoadingMessage(id: "calculating-will-won-t", text: "Calculating the will-they/won't-they odds…"),
        LoadingMessage(id: "calling-dramatic-close", text: "Calling for a dramatic close-up…"),
        LoadingMessage(id: "preparing-sweeps-week", text: "Preparing for sweeps week…"),
        LoadingMessage(id: "consulting-writers-room", text: "Consulting with the writers' room…"),
        LoadingMessage(id: "aligning-temporal-flux-matrices", text: "Aligning the temporal flux matrices…"),
        LoadingMessage(id: "defragmenting-couch-cushions", text: "Defragmenting the couch cushions…"),
        LoadingMessage(id: "compiling-sarcasm-module", text: "Compiling the sarcasm module…"),
        LoadingMessage(id: "converting-caffeine-load-time", text: "Converting caffeine into load time…"),
        LoadingMessage(id: "oscillating-wobble-registers", text: "Oscillating the wobble registers…"),
        LoadingMessage(id: "rounding-stray-electrons", text: "Rounding up the stray electrons…"),
        LoadingMessage(id: "definitely-stalling-even-little", text: "Definitely not stalling. Not even a little…"),
        LoadingMessage(id: "re-here-hasn-t", text: "We're still here. It hasn't crashed, we checked…"),
        LoadingMessage(id: "checking-if-anyone-actually", text: "Checking if anyone is actually reading these…"),
        LoadingMessage(id: "working-very-hard-appearing", text: "Working very hard at appearing to work very hard…"),
        LoadingMessage(id: "inventing-plausible-excuse-delay", text: "Inventing a plausible excuse for the delay…"),
        LoadingMessage(id: "staring-void-behalf", text: "Staring into the void on your behalf…"),
        LoadingMessage(id: "almost-ready-citation-needed", text: "Almost ready… (citation needed)…"),
        LoadingMessage(id: "ll-worth-wait-probably", text: "It'll be worth the wait. Probably…"),
        LoadingMessage(id: "progress-occurring-allegedly", text: "Progress is occurring. Allegedly…"),
        LoadingMessage(id: "end-sight-mostly", text: "The end is in sight. Mostly…"),
        LoadingMessage(id: "nearly-there-said-last", text: "Nearly there. We said that last time too…"),
        LoadingMessage(id: "any-moment-now-re", text: "Any moment now. We're fairly confident…"),
        LoadingMessage(id: "filing-paperwork-begin-filing", text: "Filing the paperwork to begin filing the paperwork…"),
        LoadingMessage(id: "awaiting-three-signatures-thumbprint", text: "Awaiting three signatures and one thumbprint…"),
        LoadingMessage(id: "waiting-committee-currently-coffee", text: "The Waiting Committee is currently on their coffee break…"),
        LoadingMessage(id: "patience-been-logged-deeply", text: "Your patience has been logged and is deeply appreciated…"),
        LoadingMessage(id: "requesting-status-update-status", text: "Requesting a status update on the status update…"),
        LoadingMessage(id: "drafting-strongly-worded-letter", text: "Drafting a strongly worded letter to the delay…"),
        LoadingMessage(id: "calculating-precise-length-moment", text: "Calculating the precise length of 'just a moment'…"),
        LoadingMessage(id: "dividing-by-zero-reconsidering", text: "Dividing by zero… reconsidering that decision…"),
        LoadingMessage(id: "measuring-patience-metric-units", text: "Measuring your patience in metric units…"),
        LoadingMessage(id: "math-checks-timeline-less", text: "The math checks out. The timeline, less so…"),
        LoadingMessage(id: "sending-intern-fetch-more", text: "Sending the intern to fetch more popcorn…"),
        LoadingMessage(id: "arguing-politely-throw-pillows", text: "Arguing politely with the throw pillows…"),
        LoadingMessage(id: "yelling-lights-camera-action", text: "Yelling 'Lights, camera, action!' at the television…"),
        LoadingMessage(id: "arranging-snack-crumbs-artistically", text: "Arranging the snack crumbs artistically…"),
        LoadingMessage(id: "rehearsing-opening-credits", text: "Rehearsing the opening credits…"),
        LoadingMessage(id: "negotiating-popcorn-prices-lobby", text: "Negotiating popcorn prices in the lobby…"),
        LoadingMessage(id: "negotiating-very-stubborn-duck", text: "Negotiating with a very stubborn duck…"),
        LoadingMessage(id: "consulting-remarkably-wise-goldfish", text: "Consulting a remarkably wise goldfish…"),
        LoadingMessage(id: "asking-nicely-then-pleading", text: "Asking nicely, then pleading, then sobbing quietly…"),
        LoadingMessage(id: "performing-minor-miracles-few", text: "Performing minor miracles (and a few medium ones)…"),
        LoadingMessage(id: "stirring-hot-chocolate", text: "Stirring the hot chocolate…"),
        LoadingMessage(id: "mixing-m-ms-popcorn", text: "Mixing the M&Ms into the popcorn…"),
        LoadingMessage(id: "rummaging-good-chocolate", text: "Rummaging for the good chocolate…"),
        LoadingMessage(id: "pouring-cider-biggest-mug", text: "Pouring the cider into the biggest mug…"),
        LoadingMessage(id: "choosing-between-salty-sweet", text: "Choosing between salty and sweet…"),
        LoadingMessage(id: "melting-cheese-nachos", text: "Melting the cheese for the nachos…"),
        LoadingMessage(id: "waiting-microwave-beep", text: "Waiting for the microwave beep…"),
        LoadingMessage(id: "arranging-snack-spread", text: "Arranging the snack spread just so…"),
        LoadingMessage(id: "locating-last-bag-gummies", text: "Locating the last bag of gummies…"),
        LoadingMessage(id: "filling-snack-bowl-critical", text: "Filling the snack bowl to critical capacity…"),
        LoadingMessage(id: "negotiating-lap-space-cat", text: "Negotiating lap space with the cat…"),
        LoadingMessage(id: "watching-dog-side-eye", text: "Watching the dog side-eye the popcorn bowl…"),
        LoadingMessage(id: "persuading-cat-share-blanket", text: "Persuading the cat to share the blanket…"),
        LoadingMessage(id: "removing-cat-fur-prime", text: "Removing cat fur from the prime viewing spot…"),
        LoadingMessage(id: "dog-claimed-spot-couch", text: "The dog has claimed your spot on the couch…"),
        LoadingMessage(id: "convincing-dog-walk", text: "Convincing the dog this is not a walk…"),
        LoadingMessage(id: "tucking-very-sleepy-cat", text: "Tucking in the very sleepy cat…"),
        LoadingMessage(id: "cat-notes-movie-choice", text: "The cat has notes on your movie choice…"),
        LoadingMessage(id: "hunting-down-warmest-throw", text: "Hunting down the warmest throw blanket…"),
        LoadingMessage(id: "wrapping-perfect-blanket-burrito", text: "Wrapping up into a perfect blanket burrito…"),
        LoadingMessage(id: "building-ideal-pillow-nest", text: "Building the ideal pillow nest…"),
        LoadingMessage(id: "untangling-blanket-last-time", text: "Untangling the blanket from last time…"),
        LoadingMessage(id: "selecting-official-movie-night", text: "Selecting the Official Movie Night Blanket…"),
        LoadingMessage(id: "debating-fluffy-blanket-versus", text: "Debating the fluffy blanket versus the weighted one…"),
        LoadingMessage(id: "lighting-popcorn-scented-candle", text: "Lighting the popcorn-scented candle…"),
        LoadingMessage(id: "drawing-curtains-total-darkness", text: "Drawing the curtains for total darkness…"),
        LoadingMessage(id: "turning-lamp-coziest-setting", text: "Turning the lamp to its coziest setting…"),
        LoadingMessage(id: "closing-curtains-perfectly-rainy", text: "Closing the curtains on a perfectly rainy night…"),
        LoadingMessage(id: "tracking-down-fuzzy-socks", text: "Tracking down the fuzzy socks…"),
        LoadingMessage(id: "waiting-pre-movie-bathroom", text: "Waiting for the pre-movie bathroom run…"),
        LoadingMessage(id: "convincing-everyone-put-phones", text: "Convincing everyone to put their phones away…"),
        LoadingMessage(id: "settling-great-big-pillow", text: "Settling the great big-pillow debate…"),
        LoadingMessage(id: "waiting-household-reach-any", text: "Waiting for the household to reach any consensus…"),
        LoadingMessage(id: "deciding-who-holds-remote", text: "Deciding who holds the remote tonight…"),
        LoadingMessage(id: "waiting-last-snack-plate", text: "Waiting for the last snack plate to be assembled…"),
        LoadingMessage(id: "shushing-group-chat-two", text: "Shushing the group chat for two hours…"),
        LoadingMessage(id: "announcing-no-spoilers-rule", text: "Announcing the No Spoilers rule…"),
        LoadingMessage(id: "listening-rain-windows", text: "Listening to the rain on the windows…"),
        LoadingMessage(id: "watching-snow-pile-outside", text: "Watching the snow pile up outside…"),
        LoadingMessage(id: "much-wow-very-wait", text: "Much wow. Very wait. Such pixels…"),
        LoadingMessage(id: "does-simply-wait-patiently", text: "One does not simply wait patiently…"),
        LoadingMessage(id: "everything-fine-pixels-fine", text: "Everything is fine. The pixels are fine. This is fine…"),
        LoadingMessage(id: "i-can-haz-content", text: "I can haz content plz…"),
        LoadingMessage(id: "definitely-rickroll-pinky-promise", text: "Definitely not a rickroll. Pinky promise…"),
        LoadingMessage(id: "pixels-belong-us", text: "All your pixels are belong to us…"),
        LoadingMessage(id: "painting-rainbows-across-cyberspace", text: "Painting rainbows across cyberspace…"),
        LoadingMessage(id: "brace-yourselves-wait-almost", text: "Brace yourselves. The wait is almost legendary…"),
        LoadingMessage(id: "consulting-magic-8-ball", text: "Consulting the Magic 8-Ball…"),
        LoadingMessage(id: "popcorn-lie", text: "The popcorn is a lie…"),
        LoadingMessage(id: "do-barrel-roll", text: "Do a barrel roll…"),
        LoadingMessage(id: "challenge-accepted", text: "Challenge accepted…"),
        LoadingMessage(id: "such-patience-very-noble", text: "Such patience. Very noble. Wow…"),
        LoadingMessage(id: "computing-answer-life-universe", text: "Computing the answer to life, the universe, and everything…"),
        LoadingMessage(id: "y-u-no-finish", text: "Y U NO finish faster…"),
        LoadingMessage(id: "keyboard-cat-warming", text: "The Keyboard Cat is warming up…"),
        LoadingMessage(id: "ceiling-cat-approves-patience", text: "Ceiling Cat approves of your patience…"),
        LoadingMessage(id: "smiling-politely-hiding-pain", text: "Smiling politely. Hiding the pain…"),
        LoadingMessage(id: "sure-if-almost-done", text: "Not sure if almost done or barely started…"),
        LoadingMessage(id: "deal-sunglasses-incoming", text: "Deal with it. Sunglasses incoming…"),
        LoadingMessage(id: "patient-young-padawan", text: "Be patient, young padawan…"),
        LoadingMessage(id: "victory-imminent-clench-fist", text: "Victory is imminent. Clench that fist…"),
        LoadingMessage(id: "mitochondria-working-overtime", text: "The mitochondria is working overtime…"),
        LoadingMessage(id: "sisyphus-nearly-top-time", text: "Sisyphus is nearly at the top this time…"),
        LoadingMessage(id: "consulting-oracle-delphi-she", text: "Consulting the Oracle of Delphi. She's being cryptic…"),
        LoadingMessage(id: "penelope-unraveling-last-night", text: "Penelope is still unraveling last night's tapestry…"),
        LoadingMessage(id: "fates-measuring-thread", text: "The Fates are measuring out the thread…"),
        LoadingMessage(id: "achilles-sitting-s-heel", text: "Achilles is sitting this one out. It's the heel…"),
        LoadingMessage(id: "king-midas-keeps-touching", text: "King Midas keeps touching things he shouldn't…"),
        LoadingMessage(id: "awaiting-word-hermes-he", text: "Awaiting word from Hermes. He's a very fast runner…"),
        LoadingMessage(id: "icarus-ignored-instructions-lesson", text: "Icarus ignored the instructions. Lesson noted…"),
        LoadingMessage(id: "loki-responsible-obviously", text: "Loki is responsible for this. Obviously…"),
        LoadingMessage(id: "odin-traded-eye-knowledge", text: "Odin traded an eye for this knowledge. Worth it…"),
        LoadingMessage(id: "rumpelstiltskin-spinning-wheel-nearly", text: "Rumpelstiltskin is at the spinning wheel. Nearly there…"),
        LoadingMessage(id: "rapunzel-let-down-her", text: "Rapunzel has let down her hair. The climb begins…"),
        LoadingMessage(id: "magic-mirror-deliberating", text: "The magic mirror is deliberating…"),
        LoadingMessage(id: "hansel-gretel-following-breadcrumbs", text: "Hansel and Gretel are still following the breadcrumbs…"),
        LoadingMessage(id: "sleeping-beauty-hit-snooze", text: "Sleeping Beauty hit snooze one more time…"),
        LoadingMessage(id: "negotiating-safe-passage-bridge", text: "Negotiating safe passage with the bridge troll…"),
        LoadingMessage(id: "ugly-duckling-having-whole", text: "The ugly duckling is having a whole moment right now…"),
        LoadingMessage(id: "monks-illuminating-manuscript", text: "The monks are still illuminating the manuscript…"),
        LoadingMessage(id: "consulting-relevant-passage-volume", text: "Consulting the relevant passage in volume XLVII…"),
        LoadingMessage(id: "waiting-plot-twist-s", text: "Waiting for the plot twist. It's on the very next page…"),
        LoadingMessage(id: "once-upon-time-happened", text: "Once upon a time, this all happened much faster…"),
        LoadingMessage(id: "quill-run-dry-fetching", text: "The quill has run dry. Fetching a fresh one…"),
        LoadingMessage(id: "town-crier-clearing-his", text: "The town crier is still clearing his throat…"),
        LoadingMessage(id: "carrier-pigeon-been-dispatched", text: "A carrier pigeon has been dispatched with the details…"),
        LoadingMessage(id: "typesetting-by-hand-letter", text: "Typesetting this by hand, one letter at a time…"),
        LoadingMessage(id: "telegram-been-dispatched-expected", text: "A telegram has been dispatched. Expected reply: Thursday…"),
        LoadingMessage(id: "pony-express-rider-saddled", text: "The Pony Express rider just saddled up…"),
        LoadingMessage(id: "roman-senate-debating-motion", text: "The Roman Senate is still debating the motion…"),
        LoadingMessage(id: "translating-hieroglyphics-patience-pharaoh", text: "Translating the hieroglyphics. Patience, pharaoh…"),
        LoadingMessage(id: "asking-sloth-time-management", text: "Asking a sloth for time management tips. It is doing its best…"),
        LoadingMessage(id: "penguin-waddling-answer-over", text: "A penguin is waddling the answer over right now…"),
        LoadingMessage(id: "waiting-tardigrade-survive-trip", text: "Waiting for the tardigrade to survive the trip and report back…"),
        LoadingMessage(id: "axolotl-can-regrow-entire", text: "An axolotl can regrow its entire heart. Drawing inspiration…"),
        LoadingMessage(id: "snail-courier-departed-dawn", text: "The snail courier departed at dawn. Three fields to go…"),
        LoadingMessage(id: "tortoise-remains-undefeated-champion", text: "The tortoise remains the undefeated champion of patience…"),
        LoadingMessage(id: "narwhal-navigating-data-fjords", text: "A narwhal is navigating the data fjords as we speak…"),
        LoadingMessage(id: "somewhere-octopus-running-three", text: "Somewhere an octopus is running three hearts and eight arms at once. Goals…"),
        LoadingMessage(id: "arctic-tern-set-commute", text: "An Arctic tern just set off on its commute. Back in six months…"),
        LoadingMessage(id: "trees-quietly-conferring-via", text: "The trees are quietly conferring via the underground fungal network…"),
        LoadingMessage(id: "lyrebird-perfectly-mimicked-sound", text: "A lyrebird just perfectly mimicked the sound of this delay…"),
        LoadingMessage(id: "deep-sea-anglerfish-lighting", text: "A deep-sea anglerfish is lighting the way from a kilometre below…"),
        LoadingMessage(id: "voyager-1-sending-regards", text: "Voyager 1 is sending its regards from 24 billion kilometres away…"),
        LoadingMessage(id: "starlight-departed-400-years", text: "That starlight departed 400 years ago and only just arrived…"),
        LoadingMessage(id: "day-venus-lasts-longer", text: "A day on Venus lasts longer than its entire year, for context…"),
        LoadingMessage(id: "moon-drifts-3-8", text: "The moon drifts 3.8 centimetres further away each year. We feel that…"),
        LoadingMessage(id: "halley-s-comet-roughly", text: "Halley's comet is roughly halfway through its return journey…"),
        LoadingMessage(id: "light-sun-takes-8", text: "Light from the sun takes 8 minutes. This is taking slightly longer…"),
        LoadingMessage(id: "new-nebula-quietly-begun", text: "A new nebula has quietly begun forming. Progress is relative…"),
        LoadingMessage(id: "have-reached-eye-storm", text: "We have reached the eye of the storm. Suspiciously serene in here…"),
        LoadingMessage(id: "lightning-bolt-five-times", text: "A lightning bolt five times hotter than the sun is on standby…"),
        LoadingMessage(id: "single-cumulus-cloud-right", text: "A single cumulus cloud right now is carrying half a billion grams of water…"),
        LoadingMessage(id: "fog-cloud-decided-lie", text: "Fog is just a cloud that decided to lie down. We relate…"),
        LoadingMessage(id: "jet-stream-took-unexpected", text: "The jet stream took an unexpected detour. Same, honestly…"),
        LoadingMessage(id: "continental-drift-moving-things", text: "Continental drift is moving things along at 5 centimetres per year…"),
        LoadingMessage(id: "stalactite-nearby-grown-approximately", text: "A stalactite nearby has grown approximately 1 millimetre since this started…"),
        LoadingMessage(id: "honey-egyptian-tomb-perfectly", text: "Honey from an Egyptian tomb is still perfectly edible. Patience pays…"),
        LoadingMessage(id: "99-9999-every-atom", text: "99.9999% of every atom is empty space. We checked. All of it…"),
        LoadingMessage(id: "geologist-gave-eta-geologically", text: "The geologist gave an ETA of 'geologically soon'…"),
        LoadingMessage(id: "evolution-favoured-patience-3", text: "Evolution has favoured patience for 3.8 billion years. You've got this…"),
        LoadingMessage(id: "waiting-oboe-finish-tuning", text: "Waiting for the oboe to finish tuning…"),
        LoadingMessage(id: "conductor-milking-fermata-s", text: "The conductor is milking the fermata for all it's worth…"),
        LoadingMessage(id: "building-perfect-midnight-mixtape", text: "Building the perfect midnight mixtape, track by track…"),
        LoadingMessage(id: "dj-flipping-record-b", text: "The DJ is flipping the record to the B-side…"),
        LoadingMessage(id: "scatting-through-delay-ba", text: "Scatting through the delay — ba-doo-wah-bop…"),
        LoadingMessage(id: "waiting-encore-everyone-already", text: "Waiting for the encore everyone already knows is coming…"),
        LoadingMessage(id: "trumpet-section-needs-more", text: "The trumpet section needs just one more run-through…"),
        LoadingMessage(id: "scanning-karaoke-songbook-perfect", text: "Scanning the karaoke songbook for the perfect choice…"),
        LoadingMessage(id: "counting-two-two-three", text: "Counting in — one, two, one-two-three-four…"),
        LoadingMessage(id: "waiting-jazz-trio-agree", text: "Waiting for the jazz trio to agree on a tempo…"),
        LoadingMessage(id: "waiting-pasta-water-boil", text: "Waiting for the pasta water to boil…"),
        LoadingMessage(id: "caramelizing-onions-genuinely-takes", text: "Caramelizing the onions — it genuinely takes forty-five minutes…"),
        LoadingMessage(id: "souffl-being-very-dramatic", text: "The soufflé is being very dramatic about this…"),
        LoadingMessage(id: "folding-cheese-simply-fold", text: "Folding in the cheese. You simply fold it in…"),
        LoadingMessage(id: "resting-roast-because-patience", text: "Resting the roast, because patience always makes it better…"),
        LoadingMessage(id: "ma-tre-d-locating", text: "The maître d' is locating your table right now…"),
        LoadingMessage(id: "tasting-sauce-making-chef", text: "Tasting the sauce and making that chef face…"),
        LoadingMessage(id: "waiting-dough-prove-own", text: "Waiting for the dough to prove in its own time…"),
        LoadingMessage(id: "kitchen-heard-nine-when", text: "The kitchen heard nine when the reservation said eight…"),
        LoadingMessage(id: "letting-garlic-bread-reach", text: "Letting the garlic bread reach its full golden glory…"),
        LoadingMessage(id: "checking-departure-board-more", text: "Checking the departure board one more time, just in case…"),
        LoadingMessage(id: "waiting-baggage-carousel-misplaced", text: "Waiting at the baggage carousel with misplaced optimism…"),
        LoadingMessage(id: "train-running-only-slightly", text: "The train is running only slightly behind schedule…"),
        LoadingMessage(id: "unfolding-paper-map-because", text: "Unfolding the paper map because the GPS was confidently wrong…"),
        LoadingMessage(id: "feeding-campfire-more-pinecone", text: "Feeding the campfire one more pinecone of hope…"),
        LoadingMessage(id: "mentally-preparing-middle-seat", text: "Mentally preparing for the middle seat…"),
        LoadingMessage(id: "hunting-rental-car-actual", text: "Hunting for the rental car in the actual correct lot…"),
        LoadingMessage(id: "inflating-air-mattress-confronting", text: "Inflating the air mattress and confronting our choices…"),
        LoadingMessage(id: "gps-recalculated-route-again", text: "The GPS has recalculated the route. Again…"),
        LoadingMessage(id: "waiting-hotel-room-technically", text: "Waiting for the hotel room to be technically ready…"),
        LoadingMessage(id: "achievement-unlocked-exceptional-patience", text: "Achievement unlocked: Exceptional Patience…"),
        LoadingMessage(id: "awaiting-respawn-timer", text: "Awaiting the respawn timer…"),
        LoadingMessage(id: "final-boss-mid-monologue", text: "The final boss is still mid-monologue. It may be a while…"),
        LoadingMessage(id: "reward-another-castle", text: "Your reward is in another castle…"),
        LoadingMessage(id: "side-quest-turned-main", text: "The side quest turned out to be the main quest all along…"),
        LoadingMessage(id: "please-insert-coin-continue", text: "Please insert coin to continue…"),
        LoadingMessage(id: "levelling-patience-stat", text: "Levelling up your patience stat…"),
        LoadingMessage(id: "grinding-experience-points-wait", text: "Grinding for experience points while you wait…"),
        LoadingMessage(id: "boss-fight-imminent-equip", text: "Boss fight imminent. Equip your snacks accordingly…"),
        LoadingMessage(id: "npc-exclamation-mark-isn", text: "The NPC with the exclamation mark isn't done talking yet…"),
        LoadingMessage(id: "secret-passage-probably-frame", text: "A secret passage is probably just out of frame…"),
        LoadingMessage(id: "speedrun-world-record-was", text: "The speedrun world record was not threatened tonight…"),
        LoadingMessage(id: "spending-skill-points-load", text: "Spending skill points on load time reduction…"),
        LoadingMessage(id: "selecting-new-game-enhanced", text: "Selecting New Game+ for the enhanced patience bonus…"),
        LoadingMessage(id: "navigating-optional-dungeon-always", text: "Navigating the optional dungeon. It always takes longer…"),
        LoadingMessage(id: "requesting-disk-2-17", text: "Requesting disk 2 of 17…"),
        LoadingMessage(id: "heads-seeking-track-40", text: "Heads seeking track 40 on Drive A:…"),
        LoadingMessage(id: "locating-turbo-button-results", text: "Locating the turbo button. Results historically mixed…"),
        LoadingMessage(id: "abort-retry-fail-choosing", text: "Abort, Retry, Fail? Choosing optimism…"),
        LoadingMessage(id: "bios-opinions-listening-respectfully", text: "The BIOS has opinions. We are listening respectfully…"),
        LoadingMessage(id: "waiting-dot-matrix-printer", text: "Waiting for the dot-matrix printer to finish composing its thoughts…"),
        LoadingMessage(id: "politely-asking-ram-remember", text: "Politely asking the RAM to remember what it was doing…"),
        LoadingMessage(id: "holding-ctrl-alt-delete", text: "Holding Ctrl+Alt+Delete as a spiritual discipline…"),
        LoadingMessage(id: "floppy-drive-working-through", text: "The floppy drive is working through some feelings…"),
        LoadingMessage(id: "running-optimal-big-o", text: "Running at optimal Big-O complexity…"),
        LoadingMessage(id: "typing-very-confidently-command", text: "Typing very confidently into the command line. Don't look…"),
        LoadingMessage(id: "performing-down-down-sequence", text: "Performing the up-up-down-down sequence. Nothing happened…"),
        LoadingMessage(id: "encoding-moment-base-64", text: "Encoding this moment in base-64 for maximum freshness…"),
        LoadingMessage(id: "there-s-no-place", text: "There's no place like 127.0.0.1 while you wait…"),
        LoadingMessage(id: "turns-delay-coming-inside", text: "Turns out the delay is coming from inside the house…"),
        LoadingMessage(id: "strongly-advising-teenager-go", text: "Strongly advising the teenager not to go into the basement…"),
        LoadingMessage(id: "twins-end-hallway-would", text: "The twins at the end of the hallway would like a word…"),
        LoadingMessage(id: "peeking-behind-shower-curtain", text: "Peeking behind the shower curtain. Just to be safe…"),
        LoadingMessage(id: "monster-been-vanquished-do", text: "The monster has been vanquished. Do not look behind you…"),
        LoadingMessage(id: "stranger-rode-town", text: "A stranger just rode into town…"),
        LoadingMessage(id: "waiting-high-noon-partner", text: "Waiting for high noon, partner…"),
        LoadingMessage(id: "sheriff-pinning-badge-speak", text: "The sheriff is pinning on the badge as we speak…"),
        LoadingMessage(id: "counting-paces-before-draw", text: "Counting out the paces before the draw…"),
        LoadingMessage(id: "was-wait-like-any", text: "It was a wait like any other. Except it wasn't…"),
        LoadingMessage(id: "adjusting-venetian-blinds-correct", text: "Adjusting the venetian blinds for the correct amount of shadow…"),
        LoadingMessage(id: "city-never-sleeps-detective", text: "The city never sleeps. The detective, momentarily, does…"),
        LoadingMessage(id: "she-walked-nothing-was", text: "She walked in. Nothing was simple after that…"),
        LoadingMessage(id: "quieting-orchestra-pit-overture", text: "Quieting the orchestra pit for the overture…"),
        LoadingMessage(id: "understudy-going-tonight-give", text: "The understudy is going on tonight. Give them a moment…"),
        LoadingMessage(id: "chorus-rehearsing-big-number", text: "The chorus is still rehearsing the big number…"),
        LoadingMessage(id: "trying-very-hard-burst", text: "Trying very hard not to burst into song right now…"),
        LoadingMessage(id: "transformation-sequence-thirty-seconds", text: "The transformation sequence is thirty seconds from completion…"),
        LoadingMessage(id: "even-final-form", text: "This is not even our final form…"),
        LoadingMessage(id: "unexpected-filler-arc-been", text: "An unexpected filler arc has been announced…"),
        LoadingMessage(id: "waiting-flashback-within-flashback", text: "Waiting for the flashback within the flashback to conclude…"),
        LoadingMessage(id: "rare-content-approaches-must", text: "The rare content approaches. We must remain very still…"),
        LoadingMessage(id: "pixels-migrate-great-numbers", text: "The pixels migrate in great numbers at this time of year…"),
        LoadingMessage(id: "here-remarkably-observe-patience", text: "And here, remarkably, we observe patience in the wild…"),
        LoadingMessage(id: "narrator-whispers-reverently-pans", text: "Our narrator whispers reverently and pans slowly to the left…"),
        LoadingMessage(id: "going-over-blueprints-last", text: "Going over the blueprints one last time…"),
        LoadingMessage(id: "casing-joint-before-main", text: "Casing the joint before the main event…"),
        LoadingMessage(id: "mastermind-explaining-plan-again", text: "The mastermind is explaining the plan. Again…"),
        LoadingMessage(id: "when-can-snatch-pixel", text: "When you can snatch the pixel from this hand, you will be ready…"),
        LoadingMessage(id: "patience-first-lesson-training", text: "Patience is the first lesson. Your training is not yet complete…"),
        LoadingMessage(id: "wax-wax-lesson-will", text: "Wax on. Wax off. The lesson will make sense shortly…"),
        LoadingMessage(id: "ancient-technique-requires-precisely", text: "The ancient technique requires precisely this long to master…"),
        LoadingMessage(id: "handpainting-title-card-speak", text: "Handpainting the title card as we speak…"),
        LoadingMessage(id: "house-front-fell-hero", text: "The house front fell. The hero emerged unscathed. Somehow…"),
        LoadingMessage(id: "pie-flight-please-stand", text: "The pie is in flight. Please stand clear of the trajectory…"),
        LoadingMessage(id: "objection-wait-been-deemed", text: "Objection! The wait has been deemed inadmissible…"),
        LoadingMessage(id: "doctor-will-shortly-please", text: "The doctor will be with you shortly. Please ignore the magazines…"),
    ]
}

/// Pure, deterministic timing logic for the loading-message experience.
///
/// Given the elapsed time since loading began, it decides whether to show only a
/// plain spinner (the first few seconds) or which playful message to display
/// once loading drags on. Keeping this free of any clock, async, or UI means the
/// threshold and cycling behaviour can be unit-tested exhaustively.
public struct LoadingMessageSequencer: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Show only the normal loading indicator (no playful message yet).
        case spinnerOnly
        /// Show the playful `message` (its position is `index` in the list).
        case message(LoadingMessage, index: Int)
    }

    /// How long to wait, showing only a spinner, before the first playful
    /// message appears. Kept generous so only a genuinely slow load ever surfaces
    /// a message — quick loads just show the spinner and finish.
    public var initialDelay: TimeInterval
    /// How long each playful message stays before cycling to the next. Paced so a
    /// viewer has time to comfortably read one before it changes.
    public var cycleInterval: TimeInterval
    /// The messages to cycle through. Empty means "spinner only, forever".
    public var messages: [LoadingMessage]

    public init(
        messages: [LoadingMessage] = LoadingMessage.playfulDefaults,
        initialDelay: TimeInterval = 6.0,
        cycleInterval: TimeInterval = 5.5
    ) {
        self.messages = messages
        self.initialDelay = initialDelay
        self.cycleInterval = cycleInterval
    }

    /// The phase to show for a given elapsed loading time.
    ///
    /// - Before `initialDelay` (or with no messages): `.spinnerOnly`.
    /// - At/after `initialDelay`: the message at `floor((elapsed - initialDelay)
    ///   / cycleInterval)`, wrapping around the list so it cycles indefinitely.
    public func phase(atElapsed elapsed: TimeInterval) -> Phase {
        guard !messages.isEmpty, elapsed >= initialDelay else { return .spinnerOnly }
        let step: Int
        if cycleInterval > 0 {
            // Nudge by a tiny epsilon so an elapsed value landing exactly on a
            // boundary advances deterministically rather than depending on FP.
            step = Int((elapsed - initialDelay + 1e-9) / cycleInterval)
        } else {
            step = 0
        }
        let index = step % messages.count
        return .message(messages[index], index: index)
    }
}

/// Persists the "shuffle bag" (a shuffled deck of message IDs plus a cursor)
/// across app launches so every playful message is shown once before any
/// repeats — even though each individual load only shows a message or two.
///
/// The deck is keyed by a `signature` of the current message set, so changing
/// the message list (adding/removing entries) naturally starts a fresh deck
/// rather than dealing stale or missing IDs.
public protocol LoadingMessageDeckStore: Sendable {
    /// Returns the saved deck order and cursor for `signature`, or `nil` if
    /// none exists yet (or it belongs to a different message set).
    func loadDeck(signature: String) -> (order: [String], cursor: Int)?
    /// Saves the deck order and cursor for `signature`.
    func saveDeck(signature: String, order: [String], cursor: Int)
}

/// `UserDefaults`-backed deck store used in production. Stores the deck order
/// and cursor under keys derived from the message-set signature so distinct
/// message sets never clobber one another.
public struct UserDefaultsLoadingMessageDeckStore: LoadingMessageDeckStore, @unchecked Sendable {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "CoreUI.LoadingMessageDeck") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func orderKey(_ signature: String) -> String { "\(keyPrefix).\(signature).order" }
    private func cursorKey(_ signature: String) -> String { "\(keyPrefix).\(signature).cursor" }

    public func loadDeck(signature: String) -> (order: [String], cursor: Int)? {
        guard let order = defaults.array(forKey: orderKey(signature)) as? [String],
              !order.isEmpty else { return nil }
        return (order, defaults.integer(forKey: cursorKey(signature)))
    }

    public func saveDeck(signature: String, order: [String], cursor: Int) {
        defaults.set(order, forKey: orderKey(signature))
        defaults.set(cursor, forKey: cursorKey(signature))
    }
}

/// Observable driver for the loading-message UI.
///
/// Starts a spinner-only phase, then (if loading is still going after
/// `initialDelay`) begins cycling playful messages on a timer. The actual sleep
/// is injected so tests can drive it deterministically; production uses
/// `Task.sleep`. Cancellation-safe: `stop()` tears down the loop.
///
/// When `shufflesMessages` is `true` (the default), message selection is driven
/// by a persistent shuffle bag (see `LoadingMessageDeckStore`) so users see the
/// whole set before repeats, with no bias toward the start of the list. When
/// `false`, messages are walked in their given order (used by tests).
@MainActor
@Observable
public final class LoadingMessageModel {
    /// The current phase the view should render.
    public private(set) var phase: LoadingMessageSequencer.Phase = .spinnerOnly

    /// The playful message currently on screen, or `nil` while spinner-only.
    public var currentMessage: LoadingMessage? {
        if case let .message(message, _) = phase { return message }
        return nil
    }

    private var sequencer: LoadingMessageSequencer
    private let shufflesMessages: Bool
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let deckStore: LoadingMessageDeckStore
    private let shuffle: @Sendable ([String]) -> [String]
    private var loop: Task<Void, Never>?

    public init(
        sequencer: LoadingMessageSequencer = LoadingMessageSequencer(),
        shufflesMessages: Bool = true,
        deckStore: LoadingMessageDeckStore = UserDefaultsLoadingMessageDeckStore(),
        shuffle: @escaping @Sendable ([String]) -> [String] = { $0.shuffled() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.sequencer = sequencer
        self.shufflesMessages = shufflesMessages
        self.deckStore = deckStore
        self.shuffle = shuffle
        self.sleep = sleep
    }

    /// Begins the spinner → message-cycling sequence. Idempotent: restarts the
    /// loop from the beginning each time.
    public func start() {
        stop()
        let seq = sequencer
        guard !seq.messages.isEmpty else { phase = .spinnerOnly; return }
        let sleep = self.sleep
        phase = .spinnerOnly
        // A non-positive cycle interval has no time axis to advance along, so the
        // first message simply holds — never spin a zero-sleep loop that would
        // peg the main actor.
        let cycles = seq.cycleInterval > 0

        guard shufflesMessages else {
            // Deterministic in-order walk (used by tests): show messages in the
            // exact order they were provided, wrapping around indefinitely.
            loop = Task { @MainActor [weak self] in
                do { try await sleep(seq.initialDelay) } catch { return }
                var step = 0
                while !Task.isCancelled {
                    guard let self else { return }
                    let elapsed = seq.initialDelay + Double(step) * seq.cycleInterval
                    self.phase = seq.phase(atElapsed: elapsed)
                    guard cycles else { return }
                    do { try await sleep(seq.cycleInterval) } catch { return }
                    step += 1
                }
            }
            return
        }

        // Persistent shuffle-bag path: deal one message per cycle from a shuffled
        // deck saved across launches, so every message is shown once before any
        // repeat and there is no bias toward the front of the list.
        let messages = seq.messages
        let ids = messages.map(\.id)
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let signature = Self.signature(of: ids)
        let store = self.deckStore
        let shuffle = self.shuffle
        loop = Task { @MainActor [weak self] in
            do { try await sleep(seq.initialDelay) } catch { return }
            // Resume the saved deck only if it matches the current message set;
            // otherwise start a fresh shuffle.
            var order: [String]
            var cursor: Int
            if let saved = store.loadDeck(signature: signature),
               Set(saved.order) == Set(ids) {
                order = saved.order
                cursor = min(max(saved.cursor, 0), order.count)
            } else {
                order = shuffle(ids)
                cursor = 0
            }
            var lastID: String?
            var step = 0
            while !Task.isCancelled {
                guard let self else { return }
                if cursor >= order.count {
                    // Deck exhausted: reshuffle. Avoid showing the same message
                    // twice in a row across the deck boundary.
                    var fresh = shuffle(ids)
                    if ids.count > 1, fresh.first == lastID { fresh.swapAt(0, 1) }
                    order = fresh
                    cursor = 0
                }
                let id = order[cursor]
                cursor += 1
                if let message = byID[id] { self.phase = .message(message, index: step) }
                lastID = id
                // Persist after showing so a mid-cycle cancellation never skips a
                // message (at worst it re-shows the last one next time).
                store.saveDeck(signature: signature, order: order, cursor: cursor)
                guard cycles else { return }
                do { try await sleep(seq.cycleInterval) } catch { return }
                step += 1
            }
        }
    }

    /// A stable, launch-independent signature of the message-ID set, used to key
    /// the persisted deck. Order-independent (sorted) so only membership matters.
    static func signature(of ids: [String]) -> String {
        // FNV-1a (64-bit) over the sorted, joined IDs — deterministic across
        // launches, unlike Swift's per-process-randomized `Hashable`.
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in ids.sorted().joined(separator: "\u{1}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return "\(ids.count)-" + String(hash, radix: 16)
    }

    /// Stops cycling and returns to spinner-only.
    public func stop() {
        loop?.cancel()
        loop = nil
        phase = .spinnerOnly
    }
}
