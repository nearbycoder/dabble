import DabbleKit
import Foundation

/// A small tour created on first launch, like Things' "Meet Things" project.
enum WelcomeContent {
    @MainActor
    static func install(in store: DabbleStore) {
        store.batch {
            let area = store.addArea("Personal")
            let project = store.addProject("Meet Dabble", area: area.id)
            store.update(Project.self, project.id) {
                $0.notes = "A quick tour. Check things off as you go, then delete this project whenever you like."
            }
            let basics = store.addHeading("The Basics", in: project.id)
            let lists = store.addHeading("Planning", in: project.id)
            let sync = store.addHeading("Sync", in: project.id)

            let tips: [(String, String, UUID)] = [
                ("Complete a to-do by clicking its checkbox", "Completed to-dos move to the Logbook.", basics.id),
                ("Open a to-do to add notes, a checklist and tags", "Notes support plain text and links.", basics.id),
                ("Collect ideas in the Inbox", "Anything you add without a place lands in the Inbox until you sort it.", basics.id),
                ("Decide when: Today, This Evening, a date, or Someday", "Today is what you'll do today. Upcoming shows what's scheduled. Anytime is everything you could do now. Someday is for maybes.", lists.id),
                ("Set a deadline to see a countdown", "Items with a deadline appear in Today when it arrives.", lists.id),
                ("Make a to-do repeat", "Completing a repeating to-do schedules the next one.", lists.id),
                ("Pair your devices", "Open Settings → Sync on one device and choose Pair New Device. Enter the code on the other. Your devices sync directly with each other — there's no server and no account.", sync.id),
            ]
            for (title, notes, heading) in tips {
                store.addToDo(title, notes: notes, in: .project(project.id), heading: heading)
            }

            let welcome = store.addToDo("Welcome to Dabble 👋", notes: "This is your Today list. Things you plan to do today live here.", in: .today)
            store.addChecklistItem("Look around the sidebar", to: welcome.id)
            store.addChecklistItem("Add your first to-do", to: welcome.id)
            let errands = store.addTag("Errands")
            store.addTag("Home")
            let milk = store.addToDo("Buy oat milk", in: .inbox)
            store.setTags(milk.id, [errands.id])
        }
    }
}
