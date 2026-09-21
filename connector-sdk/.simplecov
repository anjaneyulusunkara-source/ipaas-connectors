SimpleCov.configure do
  enable_coverage :branch
  remove_filter %r{\A(test|features|spec|autotest)/}
  skip '/spec/support'
  skip '/spec/ipaas'
end
