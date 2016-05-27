local ros = require 'ros.env'
require 'ros.actionlib.ActionClient'
local std = ros.std
local actionlib = ros.actionlib

local SimpleActionClient = torch.class('ros.actionlib.SimpleActionClient', actionlib)

local CommState = actionlib.CommState
local ZERO_DURATION = ros.Duration(0)


local SimpleGoalState = {
  PENDING     = 1,
  ACTIVE      = 2,
  DONE        = 3,
  'PENDING', 'ACTIVE', 'DONE'
}
actionlib.SimpleGoalState = SimpleGoalState


-- as returned by SimpleActionClient:getState()
local SimpleClientGoalState = {
  PENDING     = 1,
  ACTIVE      = 2,
  RECALLED    = 3,
  REJECTED    = 4,
  PREEMPTED   = 5,
  ABORTED     = 6,
  SUCCEEDED   = 7,
  LOST        = 8,
  'PENDING', 'ACTIVE', 'RECALLED', 'REJECTED', 'PREEMPTED', 'ABORTED', 'SUCCEEDED', 'LOST'
}
actionlib.SimpleClientGoalState = SimpleClientGoalState


function SimpleActionClient:__init(action_spec, name, parent_node_handle, register_spin_callback, callback_queue)
  self.callback_queue = callback_queue or ros.DEFAULT_CALLBACK_QUEUE
  self.cur_simple_state = SimpleGoalState.PENDING

  if self.callback_queue ~= ros.DEFAULT_CALLBACK_QUEUE and register_spin_callback then
    self.spin_cb = function() self.callback_queue:callAvailable(0) end
    ros.registerSpinCallback(self.spin_cb)
  end

  self.nh = ros.NodeHandle()
  self.ac = ros.actionlib.ActionClient(action_spec, name, parent_node_handle, self.callback_queue)
end


function SimpleActionClient:shutdown()
  if self.spin_cb ~= nil then
    ros.unregisterSpinCallback(self.spin_cb)
    self.spin_cb = nil
  end
  self.ac:shutdown()
end


function SimpleActionClient:waitForServer(timeout)
  return self.ac:waitForServer(timeout)
end


function SimpleActionClient:isServerConnected()
  return self.ac:isServerConnected()
end


local function setSimpleState(self, next_state)
  ros.DEBUG_NAMED(
    "SimpleActionClient", "Transitioning SimpleState from [%s] to [%s]",
    SimpleGoalState[self.cur_simple_state],
    SimpleGoalState[next_state]
  )
  self.cur_simple_state = next_state
end


local function handleTransition(self, gh)
  local comm_state = gh.state

  if comm_state == CommState.WAITING_FOR_GOAL_ACK then
    ros.ERROR_NAMED("SimpleActionClient", "BUG: Shouldn't ever get a transition callback for WAITING_FOR_GOAL_ACK")
  elseif comm_state == CommState.PENDING then
    ros.ERROR_COND(
      self.cur_simple_state ~= SimpleGoalState.PENDING,
      "BUG: Got a transition to CommState [%s] when our in SimpleGoalState [%s]",
      CommState[comm_state],
      SimpleGoalState[self.cur_simple_state]
    )
  elseif comm_state == CommState.ACTIVE then

    -- check current simple goal state
    if self.cur_simple_state == SimpleGoalState.PENDING then
      setSimpleState(self, SimpleGoalState.ACTIVE)
      if self.active_cb then
        self.active_cb()
      end
    elseif self.cur_simple_state == SimpleGoalState.ACTIVE then
      ; -- NOP
    elseif self.cur_simple_state == SimpleGoalState.DONE then
      ros.ERROR_NAMED(
        "SimpleActionClient",
        "BUG: Got a transition to CommState [%s] when in SimpleGoalState [%s]",
        CommState[comm_state],
        SimpleGoalState[self.cur_simple_state]
      )
    else
      ros.FATAL("Unknown SimpleGoalState %u", self.cur_simple_state)
    end

  elseif comm_state == CommState.WAITING_FOR_RESULT then
    ; -- NOP
  elseif comm_state == CommState.WAITING_FOR_CANCEL_ACK then
    ; -- NOP
  elseif comm_state == CommState.RECALLING then
    ros.ERROR_COND(
      self.cur_simple_state ~= SimpleGoalState.PENDING,
      "BUG: Got a transition to CommState [%s] when our in SimpleGoalState [%s]",
      CommState[comm_state],
      SimpleGoalState[self.cur_simple_state]
    )
  elseif comm_state == CommState.PREEMPTING then

    -- check current simple goal state
    if self.cur_simple_state == SimpleGoalState.PENDING then
      setSimpleState(self, SimpleGoalState.ACTIVE)
      if self.active_cb ~= nil then
        self.active_cb()
      end
    elseif self.cur_sipmle_state == SimpleGoalState.ACTIVE then
      ; -- NOP
    elseif self.cur_simple_state == SimpleGoalState.DONE then
      ros.ERROR_NAMED(
        "SimpleActionClient",
        "BUG: Got a transition to CommState [%s] when in SimpleGoalState [%s]",
        CommState[comm_state],
        SimpleGoalState[self.cur_simple_state]
      )
    else
      ros.FATAL("Unknown SimpleGoalState %u", self.cur_simple_state)
    end

 elseif comm_state == CommState.DONE then

    if self.cur_simple_state == SimpleGoalState.PENDING or
        self.cur_simple_state == SimpleGoalState.ACTIVE then

      setSimpleState(self, SimpleGoalState.DONE)
      if self.done_cb ~= nil then
        self.done_cb(self:getState(), gh:getResult())
      end

    elseif self.cur_simple_state == SimpleGoalState.DONE then
      ros.ERROR_NAMED("SimpleActionClient", "BUG: Got a second transition to DONE")
    else
      ros.FATAL("Unknown SimpleGoalState %u", self.cur_simple_state)
    end

  else
    ros.ERROR_NAMED("SimpleActionClient", "Unknown CommState received [%u]", comm_state)
  end
end


local function handleFeedback(self, goal, feedback)
  if self.gh ~= goal then
    ros.ERROR_NAMED("SimpleActionClient", "Got a callback on a goal handle that we're not tracking. This could be a GoalID collision")
  end
  if self.feedback_cb then
    self.feedback_cb(feedback)
  end
end


function SimpleActionClient:sendGoal(goal, done_cb, active_cb, feedback_cb)
  if self.gh ~= nil then
    self.gh:reset()   -- reset the old GoalHandle, so that our callbacks won't get called anymore
    self.gh = nil
  end

  self.done_cb     = done_cb
  self.active_cb   = active_cb
  self.feedback_cb = feedback_cb

  self.cur_simple_state = SimpleGoalState.PENDING

  self.gh = self.ac:sendGoal(
    goal,
    function(goal) handleTransition(self, goal) end,
    function(goal, feedback) handleFeedback(self, goal, feedback) end
  )
end


function SimpleActionClient:sendGoalAndWait(goal, execute_timeout, preempt_timeout)
  execute_timeout = execute_timeout or ros.Duration(0, 0)
  preempt_timeout = preempt_timeout or ros.Duration(0, 0)

  self:sendGoal(goal)

  -- see if the goal finishes in time
  if self:waitForResult(execute_timeout) then
    ros.DEBUG_NAMED("SimpleActionClient", "Goal finished within specified execute_timeout [%.2f]", execute_timeout:toSec())
    return self:getState()
  end

  ros.DEBUG_NAMED("SimpleActionClient", "Goal didn't finish within specified execute_timeout [%.2f]", execute_timeout:toSec())

  -- it didn't finish in time, so we need to preempt it
  self:cancelGoal()

  -- now wait again and see if it finishes
  if self:waitForResult(preempt_timeout) then
    ros.DEBUG_NAMED("SimpleActionClient", "Preempt finished within specified preempt_timeout [%.2f]", preempt_timeout:toSec())
  else
    ros.DEBUG_NAMED("SimpleActionClient", "Preempt didn't finish specified preempt_timeout [%.2f]", preempt_timeout:toSec())
  end

  return self:getState()
end


function SimpleActionClient:waitForResult(timeout)
  if self.gh == nil then
    ros.ERROR_NAMED("SimpleActionClient", "Trying to waitForGoalToFinish() when no goal is running.")
    return false
  end

  local wait_timeout = ros.Duration(0.01)

  timeout = timeout or ros.Duration(0)
  local timeout_time = ros.Time.now() + timeout
  if timeout < ros.Duration(0, 0) then
    ros.WARN_NAMED("SimpleActionClient", "Timeouts must not be negative. Timeout is [%.2fs]", timeout:toSec())
  end

  while self.nh:ok() do
    local time_left = timeout_time - ros.Time.now()
    if timeout > ZERO_DURATION and time_left < ZERO_DURATION then
      return false -- timeout
    elseif self.cur_simple_state == SimpleGoalState.DONE then
      return true -- result available
    end

    -- dispatch incomipng calls
    if not self.callback_queue:isEmpty() then
      queue:callAvailable()
    end

    -- test for terminal state again before wait operation
    if self.cur_simple_state == SimpleGoalState.DONE then
      return true
    end

    -- truncate wait-time if necessary
    if timeout > ZERO_DURATION  and time_left < wait_timeout then
      wait_timeout = time_left
    end
    self.callback_queue:waitCallAvailable(wait_timeout)
  end

  return false
end


function SimpleActionClient:getResult()
  if self.gh == nil then
    ros.ERROR_NAMED("SimpleActionClient", "Trying to getResult() when no goal is running.")
    return nil
  end
  return gh:getResult()
end


function SimpleActionClient:getState()
  if self.gh == nil then
    ros.ERROR_NAMED("SimpleActionClient", "Trying to getState() when no goal is running.")
    return SimpleClientGoalState.LOST
  end

  local comm_state = gh.state

  if comm_state == CommState.WAITING_FOR_GOAL_ACK or
      comm_state == CommState.PENDING or
      comm_state == CommState.RECALLING then
    return SimpleClientGoalState.PENDING

  elseif comm_state == CommState.ACTIVE or
         comm_state == CommState.PREEMPTING then
    return SimpleClientGoalState.ACTIVE

  elseif comm_state == CommState.Done then

    if     self.gh.state == GoalStatus.RECALLED  then return SimpleClientGoalState.RECALLED
    elseif self.gh.state == GoalStatus.REJECTED  then return SimpleClientGoalState.REJECTED
    elseif self.gh.state == GoalStatus.PREEMPTED then return SimpleClientGoalState.PREEMPTED
    elseif self.gh.state == GoalStatus.ABORTED   then return SimpleClientGoalState.ABORTED
    elseif self.gh.state == GoalStatus.SUCCEEDED then return SimpleClientGoalState.SUCCEEDED
    elseif self.gh.state == GoalStatus.LOST      then return SimpleClientGoalState.LOST
    else
      ros.ERROR_NAMED("SimpleActionClient", "Unknown terminal state [%u]. This is a bug in SimpleActionClient", self.gh.state)
      return SimpleClientGoalState.LOST
    end

  elseif comm_state == CommState.WAITING_FOR_RESULT or
         comm_state == CommState.WAITING_FOR_CANCEL_ACK then

    if self.cur_simple_state == SimpleGoalState.PENDING then
      return SimpleClientGoalState.PENDING
    elseif self.cur_simple_state == SimpleGoalState.ACTIVE then
      return SimpleClientGoalState.ACTIVE
    elseif self.cur_simple_state == SimpleGoalState.DONE then
      ros.ERROR_NAMED("SimpleActionClient", "In WAITING_FOR_RESULT or WAITING_FOR_CANCEL_ACK, yet we are in SimpleGoalState DONE. This is a bug in SimpleActionClient")
      return SimpleClientGoalState.LOST
    else
      ros.ERROR_NAMED("SimpleActionClient", "Got a SimpleGoalState of [%u]. This is a bug in SimpleActionClient", self.cur_simple_state);
    end

  end

  ros.ERROR_NAMED("SimpleActionClient", "Error trying to interpret CommState - %u", comm_state)
  return SimpleClientGoalState.LOST
end


function SimpleActionClient:cancelAllGoals()
  self.ac:cancelAllGoals()
end


function SimpleActionClient:cancelGoalsAtAndBeforeTime(time)
  self.ac:cancelGoalsAtAndBeforeTime(time)
end


function SimpleActionClient:cancelGoal()
  if self.gh == nil then
    ros.ERROR_NAMED("SimpleActionClient", "Trying to cancelGoal() when no goal is running.")
  end
  self.gh:cancel()
end


function SimpleActionClient:stopTrackingGoal()
 if self.gh == nil then
    ros.ERROR_NAMED("SimpleActionClient", "Trying to stopTrackingGoal() when no goal is running.")
  end
  self.gh:reset()
  self.gh = nil
end
