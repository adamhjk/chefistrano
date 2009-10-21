
$: << File.join(File.dirname(__FILE__), "lib")
require 'chefistrano'

role :all, "localhost"

task :testing do
  chef.recipe do
    file "/tmp/wtf"
  end
end
