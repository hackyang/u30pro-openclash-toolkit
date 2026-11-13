# Buddy 2026-11-12: merge N Clash subscriptions into ONE node pool.
# Skeleton (dns/rules/rule-providers/groups) comes from the first source.
require 'yaml'
require 'digest'
*srcs, out = ARGV
raise 'no sources' if srcs.empty?
a = YAML.load_file(srcs.first)
BOGUS = /剩余流量|距离下次重置|套餐到期|官网|流量[:：]/
merged = []; seen = {}
srcs.each do |f|
  cfg = YAML.load_file(f)
  (cfg['proxies'] || []).each do |node|
    next unless node.is_a?(Hash) && node['name']
    n = node['name'].to_s
    next if n =~ BOGUS
    if seen[n]
      n = "S2-#{n}"
      n = "#{n}-#{rand(100000)}" while seen[n]
    end
    seen[n] = true
    x = node.dup; x['name'] = n; merged << x
  end
end
raise 'too few proxies, refusing to overwrite' if merged.size < 5
a['proxies'] = merged
names = merged.map { |x| x['name'] }
(a['proxy-groups'] || []).each do |g|
  case g['name']
  when '节点选择' then g['proxies'] = ['自动选择', 'DIRECT'] + names
  when '自动选择' then g['proxies'] = names
  end
  if g['type'] == 'url-test'
    g['url'] = 'https://cp.cloudflare.com/generate_204'
    g['interval'] = 120
    g['timeout'] = 5000
    g['lazy'] = false
    g['expected-status'] = '204'
  end
end
File.write(out, YAML.dump(a))
sig_src = merged.map { |x| [x['name'], x['type'], x['server'], x['port']].join('|') }.sort.join("\n")
File.write(out + '.sig', Digest::MD5.hexdigest(sig_src))
puts "sources=#{srcs.size} merged_nodes=#{merged.size} groups=#{(a['proxy-groups']||[]).map{|g| g['name']}.inspect}"