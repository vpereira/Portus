require "rails_helper"

# Open up Portus::RegistryClient to inspect some attributes.
Portus::RegistryClient.class_eval do
  attr_reader :host, :use_ssl, :base_url, :username, :password
end

# Mock class that returns a client that can fail depending on how this class is
# initialized.
class RegistryMock < Registry
  def initialize(should_fail)
    @should_fail = should_fail
  end

  def client
    o = nil
    if @should_fail
      def o.manifest(*_)
        raise StandardError, "Some message"
      end

      def o.tags(*_)
        raise StandardError, "Some message"
      end
    else
      def o.manifest(*_)
        { "tag" => "latest" }
      end

      def o.tags(*_)
        ["latest", "0.1"]
      end
    end
    o
  end

  def get_tag_from_target_test(repo, mtype, digest)
    target = { "mediaType" => mtype, "repository" => repo, "digest" => digest }
    get_tag_from_target(target)
  end
end

# The mock client used by the RegistryReachable class.
class RegistryReachableClient < Registry
  def initialize(constant, result)
    @constant = constant
    @result   = result
  end

  def reachable?
    if @constant.nil?
      @result
    else
      raise @constant
    end
  end
end

# A Mock class for the Registry that provides a `client` method that returns an
# object that handles the `reachable?` method.
class RegistryReachable < Registry
  attr_reader :use_ssl

  def initialize(constant, result, ssl)
    @constant = constant
    @result   = result
    @use_ssl  = ssl
  end

  def client
    RegistryReachableClient.new(@constant, @result)
  end
end

describe Registry, type: :model do
  it { should have_many(:namespaces) }

  describe "after_create" do
    it "creates namespaces after_create" do
      create(:admin)
      create(:user)
      expect(Namespace.count).to be(0)

      create(:registry)
      User.all.each do |user|
        expect(Namespace.find_by(name: user.username)).not_to be(nil)
      end
    end

    it "#create_namespaces!" do
      # NOTE: the :registry factory already creates an admin
      create(:admin)
      registry = create(:registry)

      owners = registry.global_namespace.team.owners.order("username ASC")
      users = User.where(admin: true).order("username ASC")

      expect(owners.count).to be(2)
      expect(users).to match_array(owners)
    end
  end

  describe "#client" do
    let!(:registry) { create(:registry, use_ssl: true) }

    it "returns a client with the proper config" do
      client = registry.client

      expect(client.host).to eq registry.hostname
      expect(client.use_ssl).to be_truthy
      expect(client.base_url).to eq "https://#{registry.hostname}/v2/"
      expect(client.username).to eq "portus"
      expect(client.password).to eq Rails.application.secrets.portus_password
    end
  end

  # rubocop: disable Metrics/LineLength
  describe "#reachable" do
    it "returns the proper message for each scenario" do
      [
        [nil, true, true, /^$/],
        [nil, false, true, /registry does not implement v2/],
        [SocketError, true, true, /The given registry is not available/],
        [Errno::ETIMEDOUT, true, true, /connection timed out/],
        [Net::OpenTimeout, true, true, /connection timed out/],
        [Net::HTTPBadResponse, true, true, /wrong with your SSL configuration/],
        [Net::HTTPBadResponse, true, false, /Error: not using SSL/],
        [OpenSSL::SSL::SSLError, true, true, /SSL error while communicating with the registry, check the server logs for more details./],
        [OpenSSL::SSL::SSLError, true, false, /SSL error while communicating with the registry, check the server logs for more details./],
        [StandardError, true, true, /something went wrong/]
      ].each do |cs|
        rr = RegistryReachable.new(cs.first, cs[1], cs[2])
        expect(rr.reachable?).to match(cs.last)
      end
    end
  end
  # rubocop: enable Metrics/LineLength

  describe "#get_tag_from_manifest" do
    it "returns a tag on success" do
      mock = RegistryMock.new(false)

      ret = mock.get_tag_from_target_test("busybox",
                                          "application/vnd.docker.distribution.manifest.v1+json",
                                          "sha:1234")
      expect(ret).to eq "latest"
    end

    it "returns a tag on v2 manifests" do
      owner     = create(:user)
      team      = create(:team, owners: [owner])
      namespace = create(:namespace, team: team)
      repo      = create(:repository, name: "busybox", namespace: namespace)
      create(:tag, name: "latest", repository: repo)

      mock = RegistryMock.new(false)
      ret  = mock.get_tag_from_target_test("busybox",
                                           "application/vnd.docker.distribution.manifest.v2+json",
                                           "sha:1234")
      expect(ret).to eq "0.1"
    end

    it "handles errors properly" do
      m = RegistryMock.new(true)

      expect(Rails.logger).to receive(:info).with(/Could not fetch the tag/)
      expect(Rails.logger).to receive(:info).with(/Reason: Some message/)

      ret = m.get_tag_from_target_test("busybox",
                                       "application/vnd.docker.distribution.manifest.v1+prettyjws",
                                       "sha:1234")
      expect(ret).to be_nil
    end

    it "handles errors on v2" do
      mock = RegistryMock.new(true)

      expect(Rails.logger).to receive(:info).with(/Could not fetch the tag/)
      expect(Rails.logger).to receive(:info).with(/Reason: Some message/)

      ret  = mock.get_tag_from_target_test("busybox",
                                           "application/vnd.docker.distribution.manifest.v2+json",
                                           "sha:1234")
      expect(ret).to be_nil
    end

    it "raises an error when the mediaType is unknown" do
      mock = RegistryMock.new(true)

      expect(Rails.logger).to receive(:info).with(/Could not fetch the tag/)
      expect(Rails.logger).to receive(:info).with(/Reason: unsupported media type "a"/)

      mock.get_tag_from_target_test("busybox", "a", "sha:1234")
    end
  end
end
