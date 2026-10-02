#!/usr/bin/env ruby
require "json"
require "open3"
require "fileutils"
require "securerandom"

def simctl(*args)
  output, status = Open3.capture2("xcrun", "simctl", *args)
  abort "simctl #{args.first} failed" unless status.success?
  output.strip
end

device_id = ARGV.fetch(0) { abort "Usage: ruby scripts/seed-ios-screenshot-inbox.rb SIMULATOR_UUID" }
devices = JSON.parse(simctl("list", "devices", "--json")).fetch("devices").values.flatten
device = devices.find { |entry| entry["udid"] == device_id }
unless device && device["name"].start_with?("Copied iPad App Store screenshots") && device["state"] == "Booted"
  abort "Use a dedicated, booted 'Copied iPad App Store screenshots' simulator."
end
group = simctl("get_app_container", device_id, "com.magneton.copied", "group.com.magneton.copied")
unless group.include?("/CoreSimulator/Devices/#{device_id}/")
  abort "Refusing to write outside the dedicated simulator."
end
inbox = File.join(group, "ShareInbox")
abort "Inbox is not empty; launch Copied to drain it first." unless Dir.glob(File.join(inbox, "*.json")).empty?
FileUtils.mkdir_p(inbox)

samples = [
  ["Project checklist", "Review the draft\nCollect feedback\nPrepare the next release"],
  ["Swift", "func recentClippings() async throws {\n    let descriptor = FetchDescriptor<Clipping>(\n        sortBy: [SortDescriptor(\\.addDate, order: .reverse)]\n    )\n    return try modelContext.fetch(descriptor)\n}"],
  ["SwiftData documentation", "https://developer.apple.com/documentation/swiftdata", "https://developer.apple.com/documentation/swiftdata"],
  ["Meeting notes", "Design review\nKeep the layout focused.\nMake frequently used actions easy to reach."],
  ["Copied", "https://www.getcopied.app/", "https://www.getcopied.app/"],
  ["Weekend plans", "Visit the bookshop, meet for lunch, and take a walk by the lake."],
  ["JSON", "{\n  \"project\": \"Copied\",\n  \"status\": \"ready\"\n}"],
  ["Welcome", "Keep the things you copy ready for the next time you need them."]
]
now = Time.now.to_f - 978_307_200 # JSONEncoder's default Date epoch is 2001-01-01.
samples.each_with_index do |(title, text, url), index|
  id = SecureRandom.uuid.upcase
  item = { id: id, createdAt: now - index * 60, title: title, text: text,
           deviceName: "iPad Pro", source: "share" }
  item[:url] = url if url
  path = File.join(inbox, "#{id}.json")
  File.write(path, JSON.generate(item), mode: "wx")
end
puts "Queued #{samples.length} sample clippings in #{device.fetch('name')}."
puts "Launch or foreground Copied to import them through the real ShareInbox pipeline."
