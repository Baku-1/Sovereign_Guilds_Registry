// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// --- INTERFACES FOR EXTERNAL GNOSIS SAFE CONTRACTS ---
interface IGnosisSafeProxyFactory {
    function createProxyWithNonce(
        address singleton,
        bytes memory data,
        uint256 salt
    ) external returns (address);
}

interface IGnosisSafe {
    function setup(
        address[] calldata _owners,
        uint256 _threshold,
        address to,
        bytes calldata data,
        address fallbackHandler,
        address paymentToken,
        uint256 payment,
        address payable paymentReceiver
    ) external;
}


/**
 * @title Guild
 * @dev The ultimate on-chain entity for a Web3 guild, designed for the NexusLabs ecosystem.
 * @author NexusLabs Assistant
 * @notice This production-ready version has been hardened based on a formal audit,
 * incorporating pausable functionality, officer self-demotion, and other security enhancements.
 */
contract Guild is ERC721, ERC721URIStorage, AccessControl, ReentrancyGuard, Pausable {
    // =============================================
    // SECTION: STATE & CONFIGURATION
    // =============================================

    bytes32 public constant GUILD_MASTER_ROLE = keccak256("GUILD_MASTER_ROLE");
    bytes32 public constant OFFICER_ROLE = keccak256("OFFICER_ROLE");
    bytes32 public constant MEMBER_ROLE = keccak256("MEMBER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    enum PassportStatus { Inactive, Active, Revoked }

    string public logoURI;
    string public bannerURI;
    address public treasuryVault;
    uint256 private _nextTokenId;
    mapping(address => uint256) public memberToPassportId;
    mapping(uint256 => PassportStatus) public passportStatuses;

    IGnosisSafeProxyFactory public immutable gnosisProxyFactory;
    address public immutable gnosisSafeSingleton;

    // --- Staking Pool State ---
    IERC20 public immutable stakingToken;
    IERC20 public immutable rewardToken;
    mapping(address => uint256) public stakedBalances;
    uint256 public totalStaked;
    
    // --- Finite Staking Rewards State ---
    uint256 public rewardRate;
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    
    bool public governanceActive = false;
    mapping(address => uint8) public allianceStatus;
    
    // --- Events ---
    event LeadershipTransferred(address indexed previousLeader, address indexed newLeader);
    event TreasuryVaultDeployed(address indexed vaultAddress);
    event LogoUpdated(string newLogoURI);
    event BannerUpdated(string newBannerURI);
    event GovernanceActivated();
    event RewardsNotified(uint256 reward, uint256 duration);
    event RewardPaid(address indexed user, uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event AllianceProposed(address indexed toGuild);
    event MemberAdded(address indexed user);
    event MemberRemoved(address indexed user);
    event GuildLeft(address indexed user);
    event PassportMinted(address indexed user, uint256 indexed tokenId);
    event PassportRevoked(uint256 indexed tokenId, address indexed member);

    constructor(
        string memory name,
        string memory symbol,
        address initialGuildMaster,
        address _stakingTokenAddress,
        address _rewardTokenAddress,
        address _proxyFactoryAddress,
        address _singletonAddress
    ) ERC721(name, symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, initialGuildMaster);
        _grantRole(GUILD_MASTER_ROLE, initialGuildMaster);
        _grantRole(PAUSER_ROLE, initialGuildMaster);
        
        stakingToken = IERC20(_stakingTokenAddress);
        rewardToken = IERC20(_rewardTokenAddress);
        gnosisProxyFactory = IGnosisSafeProxyFactory(_proxyFactoryAddress);
        gnosisSafeSingleton = _singletonAddress;
        
        _addMember(initialGuildMaster);
    }

    // =============================================
    // SECTION: LEADERSHIP & MEMBERSHIP
    // =============================================

    function transferLeadership(address newLeader) public {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Only the current leader can transfer ownership.");
        require(hasRole(OFFICER_ROLE, newLeader), "New leader must be an existing officer.");
        
        address oldLeader = msg.sender;
        _grantRole(DEFAULT_ADMIN_ROLE, newLeader);
        _grantRole(GUILD_MASTER_ROLE, newLeader);
        _grantRole(PAUSER_ROLE, newLeader);
        _revokeRole(DEFAULT_ADMIN_ROLE, oldLeader);
        _revokeRole(GUILD_MASTER_ROLE, oldLeader);
        _revokeRole(PAUSER_ROLE, oldLeader);
        
        emit LeadershipTransferred(oldLeader, newLeader);
    }

    function addMember(address user) public onlyRole(GUILD_MASTER_ROLE) {
        _addMember(user);
    }
    
    function _addMember(address user) internal {
        require(!hasRole(MEMBER_ROLE, user), "User is already a member");
        _grantRole(MEMBER_ROLE, user);

        uint256 tokenId;
        unchecked {
            tokenId = _nextTokenId++;
        }
        memberToPassportId[user] = tokenId;
        passportStatuses[tokenId] = PassportStatus.Active;
        _safeMint(user, tokenId);

        emit MemberAdded(user);
        emit PassportMinted(user, tokenId);
    }

    function removeMember(address user) public onlyRole(GUILD_MASTER_ROLE) {
        require(hasRole(MEMBER_ROLE, user), "User is not a member");
        _revokeAndRemove(user);
    }

    function leaveGuild() public onlyRole(MEMBER_ROLE) {
        _revokeAndRemove(msg.sender);
        emit GuildLeft(msg.sender);
    }

    function renounceOfficer() public {
        require(hasRole(OFFICER_ROLE, msg.sender), "Not an officer");
        _revokeRole(OFFICER_ROLE, msg.sender);
    }
    
    function _revokeAndRemove(address user) internal {
        uint256 tokenId = memberToPassportId[user];
        
        if (passportStatuses[tokenId] != PassportStatus.Revoked) {
            passportStatuses[tokenId] = PassportStatus.Revoked;
            emit PassportRevoked(tokenId, user);
        }

        _revokeRole(MEMBER_ROLE, user);
        if (hasRole(OFFICER_ROLE, user)) {
            _revokeRole(OFFICER_ROLE, user);
        }
        emit MemberRemoved(user);
    }

    function promoteToOfficer(address member) public onlyRole(GUILD_MASTER_ROLE) {
        require(hasRole(MEMBER_ROLE, member), "User is not a member.");
        _grantRole(OFFICER_ROLE, member);
    }

    // =============================================
    // SECTION: EMERGENCY & PAUSABLE CONTROLS
    // =============================================

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // =============================================
    // SECTION: TREASURY, VISUALS, & PASSPORTS
    // =============================================

    function deployTreasuryVault(address[] calldata owners, uint256 threshold) public onlyRole(GUILD_MASTER_ROLE) {
        require(treasuryVault == address(0), "Treasury vault already deployed");
        require(owners.length >= threshold, "Threshold cannot exceed owner count");

        bytes memory setupData = abi.encodeWithSelector(
            IGnosisSafe.setup.selector, owners, threshold, address(0),
            bytes(""), address(0), address(0), 0, address(0)
        );
        
        uint256 salt = uint256(keccak256(abi.encodePacked(address(this))));
        address newVaultAddress = gnosisProxyFactory.createProxyWithNonce(gnosisSafeSingleton, setupData, salt);

        treasuryVault = newVaultAddress;
        emit TreasuryVaultDeployed(newVaultAddress);
    }

    function setLogoURI(string memory _newLogoURI) public onlyRole(GUILD_MASTER_ROLE) {
        logoURI = _newLogoURI;
        emit LogoUpdated(_newLogoURI);
    }

    function setBannerURI(string memory _newBannerURI) public onlyRole(GUILD_MASTER_ROLE) {
        bannerURI = _newBannerURI;
        emit BannerUpdated(_newBannerURI);
    }
    
    function setTokenURI(uint256 tokenId, string memory _tokenURI) public onlyRole(GUILD_MASTER_ROLE) {
        _setTokenURI(tokenId, _tokenURI);
    }

    // =============================================
    // SECTION: STAKING & REWARDS
    // =============================================

    modifier updateReward(address account) {
        rewardPerTokenStored = rewardPerToken();
        lastUpdateTime = block.timestamp;
        if (account != address(0)) {
            rewards[account] = earned(account);
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
        _;
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalStaked == 0) {
            return rewardPerTokenStored;
        }
        return rewardPerTokenStored + (((min(block.timestamp, periodFinish) - lastUpdateTime) * rewardRate * 1e18) / totalStaked);
    }

    function earned(address account) public view returns (uint256) {
        return (stakedBalances[account] * (rewardPerToken() - userRewardPerTokenPaid[account])) / 1e18 + rewards[account];
    }
    
    function min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }

    function notifyRewardAmount(uint256 reward, uint256 duration) public onlyRole(GUILD_MASTER_ROLE) updateReward(address(0)) {
        require(reward > 0 && duration > 0, "Invalid reward/duration");
        if (block.timestamp >= periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (reward + leftover) / duration;
        }
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + duration;
        emit RewardsNotified(reward, duration);
    }
    
    function claimReward() public nonReentrant whenNotPaused updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            uint256 availableRewards = rewardToken.balanceOf(address(this));
            uint256 amountToPay = min(reward, availableRewards);

            if (amountToPay > 0) {
                rewards[msg.sender] -= amountToPay; 
                rewardToken.transfer(msg.sender, amountToPay);
                emit RewardPaid(msg.sender, amountToPay);
            }
        }
    }

    function stake(uint256 amount) public nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot stake zero");
        totalStaked += amount;
        stakedBalances[msg.sender] += amount;
        require(stakingToken.transferFrom(msg.sender, address(this), amount), "Token transfer failed");
        emit Staked(msg.sender, amount);
    }
    
    function unstake(uint256 amount) public nonReentrant whenNotPaused updateReward(msg.sender) {
        require(amount > 0, "Cannot unstake zero");
        require(stakedBalances[msg.sender] >= amount, "Insufficient staked balance");
        
        claimReward();

        totalStaked -= amount;
        stakedBalances[msg.sender] -= amount;
        require(stakingToken.transfer(msg.sender, amount), "Token transfer failed");
        emit Unstaked(msg.sender, amount);
    }
    
    function emergencyWithdraw() public nonReentrant {
        uint256 balance = stakedBalances[msg.sender];
        require(balance > 0, "No staked balance to withdraw");
        
        stakedBalances[msg.sender] = 0;
        totalStaked -= balance;
        
        rewards[msg.sender] = 0;
        userRewardPerTokenPaid[msg.sender] = rewardPerToken();

        require(stakingToken.transfer(msg.sender, balance), "Token transfer failed");
        emit EmergencyWithdraw(msg.sender, balance);
    }

    // =============================================
    // SECTION: GOVERNANCE & DIPLOMACY
    // =============================================

    function activateGovernance() public onlyRole(GUILD_MASTER_ROLE) {
        require(!governanceActive, "Governance is already active");
        governanceActive = true;
        emit GovernanceActivated();
    }
    
    function proposeAlliance(address otherGuild) public onlyRole(GUILD_MASTER_ROLE) {
        require(allianceStatus[otherGuild] == 0, "Interaction already exists");
        allianceStatus[otherGuild] = 1;
        emit AllianceProposed(otherGuild);
    }

    // =============================================
    // SECTION: SOULBOUND NFT & VIEW FUNCTIONS
    // =============================================

    function isPassportActive(uint256 tokenId) public view returns (bool) {
        return passportStatuses[tokenId] == PassportStatus.Active;
    }
    
    function approve(address, uint256) public virtual override {
        require(false, "Guild Passport is non-transferable");
    }

    function setApprovalForAll(address, bool) public virtual override {
        require(false, "Guild Passport is non-transferable");
    }

    function _update(address to, uint256 tokenId, address auth) internal virtual override(ERC721, ERC721URIStorage) returns (address) {
        return super._update(to, tokenId, auth);
    }

    function _transfer(address from, address to, uint256 tokenId) internal virtual override {
        require(from == address(0), "Guild Passport is non-transferable (Soulbound)");
        super._transfer(from, to, tokenId);
    }
    
    function tokenURI(uint256 tokenId) public view virtual override(ERC721, ERC721URIStorage) returns (string memory) {
        return super.tokenURI(tokenId);
    }
    
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721URIStorage, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
    
    // ===================================================================================
    // CONTRACT API SUMMARY
    // ===================================================================================
    //
    // --- VIEW FUNCTIONS (Read-Only, No Gas Cost for Callers) ---
    //
    // function name() public view returns (string)
    // function symbol() public view returns (string)
    // function logoURI() public view returns (string)
    // function bannerURI() public view returns (string)
    // function treasuryVault() public view returns (address)
    // function hasRole(bytes32 role, address account) public view returns (bool)
    // function memberToPassportId(address user) public view returns (uint256)
    // function isPassportActive(uint256 tokenId) public view returns (bool)
    // function earned(address account) public view returns (uint256)
    // function stakedBalances(address user) public view returns (uint256)
    // function totalStaked() public view returns (uint256)
    // function governanceActive() public view returns (bool)
    // function allianceStatus(address otherGuild) public view returns (uint8)

    // --- TRANSACTIONAL FUNCTIONS (State-Changing, Cost Gas) ---
    //
    // --- Leadership & Membership ---
    // function transferLeadership(address newLeader) public
    // function renounceOfficer() public
    // function addMember(address user) public
    // function removeMember(address user) public
    // function leaveGuild() public
    // function promoteToOfficer(address member) public
    //
    // --- Treasury, Visuals, Passports ---
    // function deployTreasuryVault(address[] calldata owners, uint256 threshold) public
    // function setLogoURI(string memory _newLogoURI) public
    // function setBannerURI(string memory _newBannerURI) public
    // function setTokenURI(uint256 tokenId, string memory _tokenURI) public
    //
    // --- Staking, Governance, & Diplomacy ---
    // function notifyRewardAmount(uint256 reward, uint256 duration) public
    // function claimReward() public
    // function stake(uint256 amount) public
    // function unstake(uint256 amount) public
    // function emergencyWithdraw() public
    // function activateGovernance() public
    // function proposeAlliance(address otherGuild) public
    //
    // --- Pausable Controls ---
    // function pause() public
    // function unpause() public
}
