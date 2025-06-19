
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract AttendanceReward is ERC20, AccessControl, ReentrancyGuard, Pausable {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant PROFESSOR_ROLE = keccak256("PROFESSOR_ROLE");

    struct Student {
        bool isRegistered;
        uint256 totalAttendance;
        uint256 lastAttendanceTimestamp;
        uint256 streakCount;
        uint256 registrationTimestamp;
    }

    struct Professor {
        bool isAuthorized;
        string department;
        uint256 lecturesHeld;
        uint256 authorizationTimestamp;
    }

    mapping(address => Student) public students;
    mapping(address => Professor) public professors;
    mapping(address => mapping(uint256 => bool)) public dailyAttendance;
    mapping(uint256 => bool) public validLectureDays;

    uint256 public constant BASE_REWARD = 10 * 10**18;
    uint256 public constant STREAK_BONUS = 5 * 10**18;
    uint256 public constant PERFECT_ATTENDANCE_BONUS = 50 * 10**18;
    uint256 public constant SECONDS_PER_DAY = 86400;
    uint256 public constant MAX_STUDENTS_PER_BATCH = 100;

    uint256 public attendanceWindow = 2 hours;
    uint256 public maxDailyReward = 1000 * 10**18;
    uint256 public dayStartOffset = 5 hours + 30 minutes; // for IST (UTC+5:30)

    uint256 public lastWithdrawalTime;
    uint256 public constant WITHDRAWAL_COOLDOWN = 1 days;

    event StudentRegistered(address indexed student, uint256 timestamp);
    event ProfessorAuthorized(address indexed professor, string department, uint256 timestamp);
    event AttendanceMarked(address indexed student, address indexed professor, uint256 dayId, uint256 reward, uint256 timestamp);
    event LectureDaySet(uint256 dayId, bool isValid);
    event SecurityParametersUpdated(uint256 attendanceWindow, uint256 maxDailyReward);

    constructor() ERC20("AttendanceToken", "ATT") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
        _mint(address(this), 1000000 * 10**18);
    }

    modifier onlyValidStudent(address _student) {
        require(students[_student].isRegistered, "Student not registered");
        _;
    }

    modifier onlyAuthorizedProfessor() {
        require(hasRole(PROFESSOR_ROLE, msg.sender), "Not an authorized professor");
        _;
    }

    modifier withinAttendanceWindow(uint256 _timestamp) {
        require(
            block.timestamp >= _timestamp && 
            block.timestamp <= _timestamp + attendanceWindow,
            "Outside attendance window"
        );
        _;
    }

    function registerStudent() external nonReentrant whenNotPaused {
        require(!students[msg.sender].isRegistered, "Already registered");
        require(msg.sender != address(0), "Invalid address");

        students[msg.sender] = Student(true, 0, 0, 0, block.timestamp);
        emit StudentRegistered(msg.sender, block.timestamp);
    }

    function authorizeProfessor(address _professor, string memory _department) 
        external onlyRole(ADMIN_ROLE) nonReentrant {
        require(_professor != address(0), "Invalid professor");
        require(bytes(_department).length <= 50, "Department too long");
        require(!hasRole(PROFESSOR_ROLE, _professor), "Already authorized");

        professors[_professor] = Professor(true, _department, 0, block.timestamp);
        _grantRole(PROFESSOR_ROLE, _professor);

        emit ProfessorAuthorized(_professor, _department, block.timestamp);
    }

    function markAttendance(address[] memory _students, uint256 _lectureTimestamp)
        external onlyAuthorizedProfessor nonReentrant whenNotPaused withinAttendanceWindow(_lectureTimestamp) {
        require(_students.length > 0 && _students.length <= MAX_STUDENTS_PER_BATCH, "Invalid student batch");

        uint256 dayId = _calculateDayId(_lectureTimestamp);
        require(validLectureDays[dayId], "Invalid lecture day");

        professors[msg.sender].lecturesHeld++;

        for (uint256 i = 0; i < _students.length; i++) {
            address student = _students[i];
            require(student != address(0) && student != msg.sender, "Invalid student");
            require(students[student].isRegistered, "Not registered");
            require(!dailyAttendance[student][dayId], "Already marked");

            dailyAttendance[student][dayId] = true;
            students[student].totalAttendance++;

            uint256 reward = _calculateReward(student, dayId);
            students[student].lastAttendanceTimestamp = _lectureTimestamp;

            require(balanceOf(address(this)) >= reward, "Insufficient balance");
            _transfer(address(this), student, reward);

            emit AttendanceMarked(student, msg.sender, dayId, reward, block.timestamp);
        }
    }

    function _calculateDayId(uint256 _timestamp) internal view returns (uint256) {
        return (_timestamp + dayStartOffset) / SECONDS_PER_DAY;
    }

    function _calculateReward(address _student, uint256 _dayId) internal returns (uint256 reward) {
        reward = BASE_REWARD;
        uint256 lastDayId = _calculateDayId(students[_student].lastAttendanceTimestamp);

        if (students[_student].lastAttendanceTimestamp > 0 && _dayId == lastDayId + 1) {
            students[_student].streakCount++;
            if (students[_student].streakCount >= 2) {
                reward += STREAK_BONUS;
            }
        } else {
            students[_student].streakCount = 1;
        }

        if (reward > maxDailyReward) {
            reward = maxDailyReward;
        }
    }

    function setValidLectureDays(uint256[] memory _dayIds, bool _isValid) external onlyRole(ADMIN_ROLE) {
        for (uint256 i = 0; i < _dayIds.length; i++) {
            validLectureDays[_dayIds[i]] = _isValid;
            emit LectureDaySet(_dayIds[i], _isValid);
        }
    }

    function updateSecurityParameters(uint256 _window, uint256 _maxReward) external onlyRole(ADMIN_ROLE) {
        require(_window >= 1 hours && _window <= 24 hours, "Invalid window");
        require(_maxReward >= BASE_REWARD, "Reward too low");
        attendanceWindow = _window;
        maxDailyReward = _maxReward;
        emit SecurityParametersUpdated(_window, _maxReward);
    }

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function emergencyWithdraw(uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(block.timestamp >= lastWithdrawalTime + WITHDRAWAL_COOLDOWN, "Cooldown active");
        require(_amount <= balanceOf(address(this)) / 10, "Exceeds limit");
        require(balanceOf(address(this)) >= _amount, "Insufficient funds");
        lastWithdrawalTime = block.timestamp;
        _transfer(address(this), msg.sender, _amount);
    }

    function addTokensToContract(uint256 _amount) external onlyRole(ADMIN_ROLE) {
        require(_amount > 0, "Zero amount");
        _mint(address(this), _amount);
    }

    function revokeProfessor(address _professor) external onlyRole(ADMIN_ROLE) {
        require(hasRole(PROFESSOR_ROLE, _professor), "Not a professor");
        professors[_professor].isAuthorized = false;
        _revokeRole(PROFESSOR_ROLE, _professor);
    }

    function getCurrentDayId() external view returns (uint256) {
        return _calculateDayId(block.timestamp);
    }

    function isValidLectureDay(uint256 _dayId) external view returns (bool) {
        return validLectureDays[_dayId];
    }

    function getStudentStats(address _student) external view returns (
        bool, uint256, uint256, uint256, uint256, uint256
    ) {
        Student memory s = students[_student];
        return (
            s.isRegistered,
            s.totalAttendance,
            s.streakCount,
            balanceOf(_student),
            s.lastAttendanceTimestamp,
            s.registrationTimestamp
        );
    }

    function getProfessorStats(address _professor) external view returns (
        bool, string memory, uint256, uint256
    ) {
        Professor memory p = professors[_professor];
        return (
            p.isAuthorized,
            p.department,
            p.lecturesHeld,
            p.authorizationTimestamp
        );
    }
}
