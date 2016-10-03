# git_version.rb
Facter.add('git_version') do
  setcode do
    Facter::Core::Execution.exec('git --version')
  end
end
