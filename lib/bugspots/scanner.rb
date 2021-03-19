require "rugged"

module Bugspots
  Fix = Struct.new(:message, :date, :files)
  Spot = Struct.new(:file, :percentile, :score)

  def self.scan(repo, branch = "master", depth = nil, regex = nil, churn = nil)
    # regex ||= /\b(fix(es|ed)?|close(s|d)?)\b/i
    regex ||= /.+/
    fixes = []
    diff = []
    diff_spots = [];

    repo_dir = repo
    repo = Rugged::Repository.new(repo)
    unless repo.branches.each_name(:local).sort.find { |b| b == branch }
      raise ArgumentError, "no such branch in the repo: #{branch}"
    end

    pp repo.branches[branch].target

    if churn && !repo.branches.each_name(:local).sort.find { |b| b == churn }
      raise ArgumentError, "no such branch in the repo: #{churn}"
    end
    diff = Dir.chdir(repo_dir) do
     `git diff --name-only origin/master..`.split(/\n/)
    end

    walker = Rugged::Walker.new(repo)
    walker.sorting(Rugged::SORT_TOPO)
    walker.push(repo.branches[branch].target)
    walker = walker.take(depth) if depth
    walker.each do |commit|
      if commit.message.scrub =~ regex
        files = commit.diff(commit.parents.first).deltas.collect do |d|
          d.old_file[:path]
        end
        fixes << Fix.new(commit.message.scrub.split("\n").first, commit.time, files)
      end
    end

    hotspots = Hash.new(0)
    currentTime = Time.now
    oldest_fix_date = fixes.last.date
    fixes.each do |fix|
      fix.files.each do |file|
        # The timestamp used in the equation is normalized from 0 to 1, where
        # 0 is the earliest point in the code base, and 1 is now (where now is
        # when the algorithm was run). Note that the score changes over time
        # with this algorithm due to the moving normalization; it's not meant
        # to provide some objective score, only provide a means of comparison
        # between one file and another at any one point in time
        t = 1 - ((currentTime - fix.date).to_f / (currentTime - oldest_fix_date))
        hotspots[file] += 1/(1+Math.exp((-12*t)+12))
      end
    end

    sorted_hotspots = hotspots.sort_by {|k,v| v}.reverse.collect
    top_spot = sorted_hotspots.first
    rank = 0
    size = hotspots.size

    spots = sorted_hotspots.each do |spot|
      percentile = (((size.to_f - rank)/size)*100).round(0)
      s = Spot.new(spot.first, percentile, sprintf('%.4f', (spot.last/top_spot.last)*100))
      diff_spots.append(s) if diff.include?(spot.first)
      rank = rank + 1
      s
    end

    return fixes, spots, diff_spots
  end
end
