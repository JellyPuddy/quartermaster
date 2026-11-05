# frozen_string_literal: true

# Story 6, away from the desk: the phone page, generated locally and never
# published. `qm overview --json` writes the snapshot the /work-items skill
# would upload; phone/index.html is the skill's real page.html with a small
# stand-in for the artifact's data store put in front of it, answering
# overview/current with that snapshot. Open the file in a browser (at phone
# width) to see what the phone shows.
module DemoWorld
  module Phone
    PAGE = File.expand_path("../../../skills/work-items/page.html", __dir__)

    def self.store_shim(snapshot)
      <<~HTML
        <script>
        // Demo world only: the artifact runtime's db, answering from a local snapshot.
        window.claude = { use: async () => ({ doc: () => {
          const snap = { exists: true, data: () => (#{JSON.generate(snapshot).gsub("</", "<\\/")}) };
          return { onSnapshot: (ok) => ok(snap), get: async () => snap };
        } }) };
        </script>
      HTML
    end
  end
end

DemoWorld.step("phone") do |world|
  dir = File.join(world.root, "phone")
  FileUtils.mkdir_p(dir)
  json = File.join(dir, "overview.json")
  world.qm!("overview", "--json", json)
  page = File.read(DemoWorld::Phone::PAGE)
  shim = DemoWorld::Phone.store_shim(JSON.parse(File.read(json)))
  File.write(File.join(dir, "index.html"), page.sub("<script>", "#{shim}<script>"))
end
