/**
 * @file config_manager.xc
 * @brief EtherCAT Motor Drive Configuration Manager
 * @author Synapticon GmbH <support@synapticon.com>
 */

#include <stdint.h>
#include <dictionary_symbols.h>
#include <state_modes.h>
#include <position_feedback_service.h>
#include "config_manager.h"
#include <xs1.h>

void cm_sync_config_hall_states(
        client interface i_coe_communication i_coe,
        client interface PositionFeedbackInterface i_pos_feedback,
        interface TorqueControlInterface client ?i_torque_control,
        PositionFeedbackConfig &feedback_config,
        MotorcontrolConfig &motorcontrol_config,
        int sensor_index)
{
    if (feedback_config.sensor_type != HALL_SENSOR) {
        return;
    }

    uint16_t feedback_sensor_object = i_coe.get_object_value(DICT_FEEDBACK_SENSOR_PORTS, sensor_index);

    /* See Wrike https://www.wrike.com/workspace.htm#path=folder&id=127649023&a=1384194&c=list&t=135832278&ot=135832278&so=5&sd=0
     * for more information.
     */
    motorcontrol_config.commutation_sensor  = feedback_config.sensor_type;
    motorcontrol_config.hall_state_angle[0] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_0);
    motorcontrol_config.hall_state_angle[1] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_1);
    motorcontrol_config.hall_state_angle[2] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_2);
    motorcontrol_config.hall_state_angle[3] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_3);
    motorcontrol_config.hall_state_angle[4] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_4);
    motorcontrol_config.hall_state_angle[5] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_5);
}

int cm_sync_config_position_feedback(
        client interface i_coe_communication i_coe,
        client interface PositionFeedbackInterface i_pos_feedback,
        PositionFeedbackConfig &config, int feedback_service_index,
        int &sensor_commutation, int &sensor_motion_control,
        int number_of_ports, int &port_index)
{
    config = i_pos_feedback.get_config();
    int restart = 0;

    uint16_t feedback_sensor_object = 0;
    SensorFunction sensor_function = 0;

    //go through all ports until we found one in use
    for (int i=port_index; i<=number_of_ports; i++) {
        feedback_sensor_object = i_coe.get_object_value(DICT_FEEDBACK_SENSOR_PORTS, i);
        if (feedback_sensor_object != 0) {
            sensor_function = i_coe.get_object_value(feedback_sensor_object, 2);
            if (sensor_function != SENSOR_FUNCTION_DISABLED) {
                // detect which position feedback service (1 or 2) is used for commutation or motion control
                // this is used later for multiple things like: sensor resolution (for profiler), tuning (for setting the pole pairs)
                switch(sensor_function) {
                case SENSOR_FUNCTION_COMMUTATION_AND_MOTION_CONTROL:
                    sensor_commutation = feedback_service_index;
                    sensor_motion_control = feedback_service_index;
                    break;
                case SENSOR_FUNCTION_COMMUTATION_AND_FEEDBACK_DISPLAY_ONLY:
                    sensor_commutation = feedback_service_index;
                    break;
                case SENSOR_FUNCTION_COMMUTATION_ONLY:
                    sensor_commutation = feedback_service_index;
                    break;
                case SENSOR_FUNCTION_MOTION_CONTROL:
                    sensor_motion_control = feedback_service_index;
                    break;
                }
                port_index = i; //the port we will configure now
                break;
            } else {
                feedback_sensor_object = 0;
            }
        }
    }

    int old_sensor_type = config.sensor_type; //too check if we need to restart the service

    if (feedback_sensor_object != 0) {
        config.sensor_type             = i_coe.get_object_value(feedback_sensor_object, 1);
        config.sensor_function         = sensor_function;
        config.resolution              = i_coe.get_object_value(feedback_sensor_object, 3);
        config.velocity_compute_period = i_coe.get_object_value(feedback_sensor_object, 4);
        config.polarity                = i_coe.get_object_value(feedback_sensor_object, 5);
        config.pole_pairs              = i_coe.get_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_POLE_PAIRS);
        config.offset                  = i_coe.get_object_value(DICT_HOME_OFFSET, 0);

        // sensor specific parameters
        // use port_index to select the port number used for hall, qei or biss
        EncoderPortNumber encoder_port_number = ENCODER_PORT_1;
        if (port_index != 1) {
            encoder_port_number = ENCODER_PORT_2;
        }
        switch (config.sensor_type) {
        case QEI_SENSOR:
            QEI_SignalType old_qei_signal_type = config.qei_config.signal_type;
            config.qei_config.signal_type        = i_coe.get_object_value(feedback_sensor_object, SUB_INCREMENTAL_ENCODER_ACCESS_SIGNAL_TYPE);
            if (config.qei_config.signal_type != old_qei_signal_type || config.qei_config.port_number != encoder_port_number) {
                restart = 1;
            }
            config.qei_config.number_of_channels = i_coe.get_object_value(feedback_sensor_object, SUB_INCREMENTAL_ENCODER_NUMBER_OF_CHANNELS);
            config.qei_config.port_number        = encoder_port_number;
            break;

        case BISS_SENSOR:
            BISSClockPortConfig old_biss_clock_port_config = config.biss_config.clock_port_config;
            int old_biss_clock_frequency = config.biss_config.clock_frequency;
            config.biss_config.clock_port_config    = i_coe.get_object_value(feedback_sensor_object, SUB_BISS_ENCODER_CLOCK_PORT_CONFIG); /* FIXME add check for valid enum data of clock_port_config */
            config.biss_config.clock_frequency      = i_coe.get_object_value(feedback_sensor_object, SUB_BISS_ENCODER_CLOCK_FREQUENCY);
            if (config.biss_config.clock_port_config != old_biss_clock_port_config ||
                    config.biss_config.clock_frequency != old_biss_clock_frequency ||
                    config.biss_config.data_port_number != encoder_port_number)
            {
                restart = 1;
            }
            config.biss_config.multiturn_resolution = i_coe.get_object_value(feedback_sensor_object, SUB_BISS_ENCODER_MULTITURN_RESOLUTION);
            config.biss_config.timeout              = i_coe.get_object_value(feedback_sensor_object, SUB_BISS_ENCODER_TIMEOUT);
            config.biss_config.crc_poly             = i_coe.get_object_value(feedback_sensor_object, SUB_BISS_ENCODER_CRC_POLYNOM);
            config.biss_config.filling_bits         = i_coe.get_object_value(feedback_sensor_object, SUB_BISS_ENCODER_NUMBER_OF_FILLING_BITS);
            config.biss_config.busy                 = i_coe.get_object_value(feedback_sensor_object, SUB_BISS_ENCODER_NUMBER_OF_BITS_TO_READ_WHILE_BUSY);
            config.biss_config.data_port_number     = encoder_port_number;
            break;

        case HALL_SENSOR:
            if (config.hall_config.port_number != encoder_port_number) {
                restart = 1;
            }
            config.hall_config.port_number = encoder_port_number;
            break;

        case REM_14_SENSOR:
            config.rem_14_config.hysteresis              = i_coe.get_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_HYSTERESIS);
            config.rem_14_config.noise_settings          = i_coe.get_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_NOISE_SETTINGS);
            config.rem_14_config.dyn_angle_error_comp    = i_coe.get_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_DYNAMIC_ANGLE_ERROR_COMPENSATION);
            config.rem_14_config.abi_resolution_settings = i_coe.get_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_RESOLUTION_SETTINGS);
            break;

        case REM_16MT_SENSOR:
            config.rem_16mt_config.filter = i_coe.get_object_value(feedback_sensor_object, SUB_REM_16MT_ENCODER_FILTER);
            break;
        }

        //gpio settings (gpio are always on the first position feedback service)
        if (feedback_service_index == 1)
            for (int i=0; i<4; i++) {
                config.gpio_config[i] = i_coe.get_object_value(DICT_GPIO, i+1);
            }

        port_index++; //the next port to check
    } else { //disable service if not set
        config.sensor_type = 0;
        config.sensor_function = SENSOR_FUNCTION_DISABLED;
    }

    //restart the service if the sensor type is changed
    if (old_sensor_type != config.sensor_type) {
        restart = 1;
    }

    i_pos_feedback.set_config(config);

    return restart;
}

int cm_sync_config_motor_control(
        client interface i_coe_communication i_coe,
        interface TorqueControlInterface client ?i_torque_control,
        MotorcontrolConfig &motorcontrol_config,
        int sensor_commutation,
        int sensor_commutation_type)
{
    if (isnull(i_torque_control))
        return motorcontrol_config.max_torque;

    motorcontrol_config = i_torque_control.get_config();

    motorcontrol_config.dc_bus_voltage           = i_coe.get_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_DC_BUS_VOLTAGE);
    motorcontrol_config.phases_inverted          = i_coe.get_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_MOTOR_PHASES_INVERTED);
    motorcontrol_config.torque_P_gain            = i_coe.get_object_value(DICT_TORQUE_CONTROLLER, SUB_TORQUE_CONTROLLER_CONTROLLER_KP);
    motorcontrol_config.torque_I_gain            = i_coe.get_object_value(DICT_TORQUE_CONTROLLER, SUB_TORQUE_CONTROLLER_CONTROLLER_KI);
    motorcontrol_config.torque_D_gain            = i_coe.get_object_value(DICT_TORQUE_CONTROLLER, SUB_TORQUE_CONTROLLER_CONTROLLER_KD);
    motorcontrol_config.pole_pairs               = i_coe.get_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_POLE_PAIRS);
    motorcontrol_config.commutation_sensor       = sensor_commutation_type;
    motorcontrol_config.commutation_angle_offset = i_coe.get_object_value(DICT_COMMUTATION_ANGLE_OFFSET, 0);
    motorcontrol_config.phase_resistance         = i_coe.get_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_PHASE_RESISTANCE);
    motorcontrol_config.phase_inductance         = i_coe.get_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_PHASE_INDUCTANCE);
    motorcontrol_config.torque_constant          = i_coe.get_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_TORQUE_CONSTANT);
    motorcontrol_config.rated_current            = i_coe.get_object_value(DICT_MOTOR_RATED_CURRENT, 0);
    motorcontrol_config.rated_torque             = i_coe.get_object_value(DICT_MOTOR_RATED_TORQUE, 0);
    if (motorcontrol_config.rated_torque == 0) {
        motorcontrol_config.rated_torque = 1;
    }
    motorcontrol_config.max_torque               = (i_coe.get_object_value(DICT_MAX_TORQUE, 0)*motorcontrol_config.rated_torque)/1000; // in 1/1000 of rated torque
    motorcontrol_config.percent_offset_torque    = i_coe.get_object_value(DICT_APPLIED_TUNING_TORQUE_PERCENT, 0);
    /* Read protection limits */
    motorcontrol_config.protection_limit_over_current  = i_coe.get_object_value(DICT_PROTECTION, SUB_PROTECTION_MAX_CURRENT);
    motorcontrol_config.protection_limit_under_voltage = i_coe.get_object_value(DICT_PROTECTION, SUB_PROTECTION_MIN_DC_VOLTAGE);
    motorcontrol_config.protection_limit_over_voltage  = i_coe.get_object_value(DICT_PROTECTION, SUB_PROTECTION_MAX_DC_VOLTAGE);
    //FIXME: missing motorcontrol_config.protection_limit_over_temperature

    uint16_t feedback_sensor_object = 0;
    feedback_sensor_object = i_coe.get_object_value(DICT_FEEDBACK_SENSOR_PORTS, sensor_commutation); //select which hall config to read
    if (feedback_sensor_object == DICT_HALL_SENSOR_1 || feedback_sensor_object == DICT_HALL_SENSOR_2) {
        motorcontrol_config.hall_state_angle[0] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_0);
        motorcontrol_config.hall_state_angle[1] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_1);
        motorcontrol_config.hall_state_angle[2] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_2);
        motorcontrol_config.hall_state_angle[3] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_3);
        motorcontrol_config.hall_state_angle[4] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_4);
        motorcontrol_config.hall_state_angle[5] = i_coe.get_object_value(feedback_sensor_object, SUB_HALL_SENSOR_STATE_ANGLE_5);
    }

    i_torque_control.set_config(motorcontrol_config);

    return motorcontrol_config.max_torque;
}

void cm_sync_config_profiler(
        client interface i_coe_communication i_coe,
        ProfilerConfig &profiler,
        enum eProfileType type)
{
    profiler.min_position     =  i_coe.get_object_value(DICT_MAX_SOFTWARE_POSITION_RANGE_LIMIT, 1);
    profiler.max_position     =  i_coe.get_object_value(DICT_MAX_SOFTWARE_POSITION_RANGE_LIMIT, 2);
    profiler.acceleration     =  i_coe.get_object_value(DICT_PROFILE_ACCELERATION, 0);
    profiler.deceleration     =  i_coe.get_object_value(DICT_PROFILE_DECELERATION, 0);
    profiler.max_velocity     =  i_coe.get_object_value(DICT_MAX_PROFILE_VELOCITY, 0);
    profiler.max_deceleration =  profiler.deceleration;
    profiler.max_acceleration =  i_coe.get_object_value(DICT_PROFILE_ACCELERATION, 0);
    profiler.velocity         =  i_coe.get_object_value(DICT_MAX_PROFILE_VELOCITY, 0);
}

void cm_sync_config_pos_velocity_control(
        client interface i_coe_communication i_coe,
        client interface MotionControlInterface i_motion_control,
        MotionControlConfig &position_config,
        int sensor_resolution,
        int max_torque)
{
    i_motion_control.get_motion_control_config();

    //limits
    position_config.min_pos_range_limit = i_coe.get_object_value(DICT_POSITION_RANGE_LIMITS, SUB_POSITION_RANGE_LIMITS_MIN_POSITION_RANGE_LIMIT);
    position_config.max_pos_range_limit = i_coe.get_object_value(DICT_POSITION_RANGE_LIMITS, SUB_POSITION_RANGE_LIMITS_MAX_POSITION_RANGE_LIMIT);
    position_config.max_motor_speed     = i_coe.get_object_value(DICT_MAX_MOTOR_SPEED, 0);
    position_config.max_torque          = max_torque;

    position_config.enable_profiler = i_coe.get_object_value(DICT_MOTION_PROFILE_TYPE, 0); //FIXME: profiler setting missing
    position_config.resolution      = sensor_resolution;
    position_config.filter          = i_coe.get_object_value(DICT_FILTER_COEFFICIENTS, SUB_FILTER_COEFFICIENTS_POSITION_FILTER_COEFFICIENT);

    position_config.position_control_strategy = i_coe.get_object_value(DICT_POSITION_CONTROL_STRATEGY, 0);

    position_config.position_kp                   = i_coe.get_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_CONTROLLER_KP);
    position_config.position_ki                   = i_coe.get_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_CONTROLLER_KI);
    position_config.position_kd                   = i_coe.get_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_CONTROLLER_KD);
    position_config.position_integral_limit       = i_coe.get_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_POSITION_INTEGRAL_LIMIT);
    position_config.moment_of_inertia             = i_coe.get_object_value(DICT_MOMENT_OF_INERTIA, 0);

    position_config.velocity_kp              = i_coe.get_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_KP);
    position_config.velocity_ki              = i_coe.get_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_KI);
    position_config.velocity_kd              = i_coe.get_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_KD);
    position_config.velocity_integral_limit = i_coe.get_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_INTEGRAL_LIMIT);

    /* Brake control settings */
    position_config.brake_release_strategy = i_coe.get_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_BRAKE_RELEASE_STRATEGY);
    position_config.brake_release_delay  = i_coe.get_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_BRAKE_RELEASE_DELAY);
    position_config.dc_bus_voltage        = i_coe.get_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_DC_BUS_VOLTAGE);
    position_config.pull_brake_voltage    = i_coe.get_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_PULL_BRAKE_VOLTAGE);
    position_config.pull_brake_time       = i_coe.get_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_PULL_BRAKE_TIME);
    position_config.hold_brake_voltage    = i_coe.get_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_HOLD_BRAKE_VOLTAGE);

    i_motion_control.set_motion_control_config(position_config);
}

/*
 *  Set default parameters from current configuration
 */

void cm_default_config_position_feedback(
        client interface i_coe_communication i_coe,
        client interface PositionFeedbackInterface i_pos_feedback,
        PositionFeedbackConfig &config,
        int feedback_service_index)
{
    config = i_pos_feedback.get_config();

    int port_index = 1;
    uint16_t feedback_sensor_object = 0;

    // select where to store the parameters
    switch(config.sensor_type) {
    case QEI_SENSOR:
        if (config.qei_config.port_number == ENCODER_PORT_1) {
            feedback_sensor_object = DICT_INCREMENTAL_ENCODER_1;
        } else {
            port_index = 2;
            feedback_sensor_object = DICT_INCREMENTAL_ENCODER_2;
        }
        break;
    case BISS_SENSOR:
        if (config.biss_config.data_port_number == ENCODER_PORT_1) {
            feedback_sensor_object = DICT_BISS_ENCODER_1;
        } else {
            port_index = 2;
            feedback_sensor_object = DICT_BISS_ENCODER_2;
        }
        break;
    case HALL_SENSOR:
        if (config.hall_config.port_number == ENCODER_PORT_1) {
            feedback_sensor_object = DICT_HALL_SENSOR_1;
        } else {
            port_index = 2;
            feedback_sensor_object = DICT_HALL_SENSOR_2;
        }
        break;
    case REM_14_SENSOR:
        feedback_sensor_object = DICT_REM_14_ENCODER;
        port_index = 3;
        break;
    case REM_16MT_SENSOR:
        feedback_sensor_object = DICT_REM_16MT_ENCODER;
        port_index = 3;
        break;
    }

    if (feedback_sensor_object != 0) {
        i_coe.set_object_value(DICT_FEEDBACK_SENSOR_PORTS, port_index, feedback_sensor_object);


        // generic sensor parameters
        i_coe.set_object_value(feedback_sensor_object, 2, config.sensor_function);
        i_coe.set_object_value(feedback_sensor_object, 3, config.resolution);
        i_coe.set_object_value(feedback_sensor_object, 4, config.velocity_compute_period);
        i_coe.set_object_value(feedback_sensor_object, 5, config.polarity);
        i_coe.set_object_value(DICT_HOME_OFFSET, 0, config.offset);

        // sensor specific parameters
        switch (config.sensor_type) {
        case QEI_SENSOR:
            i_coe.set_object_value(feedback_sensor_object, 1, QEI_SENSOR);
            i_coe.set_object_value(feedback_sensor_object, SUB_INCREMENTAL_ENCODER_NUMBER_OF_CHANNELS, config.qei_config.number_of_channels);
            i_coe.set_object_value(feedback_sensor_object, SUB_INCREMENTAL_ENCODER_ACCESS_SIGNAL_TYPE,config.qei_config.signal_type);
            break;

        case BISS_SENSOR:
            i_coe.set_object_value(feedback_sensor_object, 1, BISS_SENSOR);
            i_coe.set_object_value(feedback_sensor_object, SUB_BISS_ENCODER_MULTITURN_RESOLUTION, config.biss_config.multiturn_resolution);
            i_coe.set_object_value(feedback_sensor_object, SUB_BISS_ENCODER_CLOCK_FREQUENCY, config.biss_config.clock_frequency);
            i_coe.set_object_value(feedback_sensor_object, SUB_BISS_ENCODER_TIMEOUT, config.biss_config.timeout);
            i_coe.set_object_value(feedback_sensor_object, SUB_BISS_ENCODER_CRC_POLYNOM, config.biss_config.crc_poly);
            i_coe.set_object_value(feedback_sensor_object, SUB_BISS_ENCODER_CLOCK_PORT_CONFIG, config.biss_config.clock_port_config); /* FIXME add check for valid enum data of clock_port_config */
            i_coe.set_object_value(feedback_sensor_object, SUB_BISS_ENCODER_NUMBER_OF_FILLING_BITS,config.biss_config.filling_bits);
            i_coe.set_object_value(feedback_sensor_object, SUB_BISS_ENCODER_NUMBER_OF_BITS_TO_READ_WHILE_BUSY,config.biss_config.busy);
            break;

        case HALL_SENSOR:
            i_coe.set_object_value(feedback_sensor_object, 1, HALL_SENSOR);
            break;

        case REM_14_SENSOR:
            i_coe.set_object_value(feedback_sensor_object, 1, REM_14_SENSOR);
            i_coe.set_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_HYSTERESIS, config.rem_14_config.hysteresis);
            i_coe.set_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_NOISE_SETTINGS, config.rem_14_config.noise_settings);
            i_coe.set_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_DYNAMIC_ANGLE_ERROR_COMPENSATION, config.rem_14_config.dyn_angle_error_comp);
            i_coe.set_object_value(feedback_sensor_object, SUB_REM_14_ENCODER_RESOLUTION_SETTINGS, config.rem_14_config.abi_resolution_settings);
            break;

        case REM_16MT_SENSOR:
            i_coe.set_object_value(feedback_sensor_object, 1, REM_16MT_SENSOR);
            i_coe.set_object_value(feedback_sensor_object, SUB_REM_16MT_ENCODER_FILTER, config.rem_16mt_config.filter);
            break;
        }
    }


    //gpio settings (only for the first position feedback service)
    if (feedback_service_index == 1)
    for (int i=0; i<4; i++) {
        i_coe.set_object_value(DICT_GPIO, i+1, config.gpio_config[i]);
    }
}

void cm_default_config_motor_control(
        client interface i_coe_communication i_coe,
        interface TorqueControlInterface client ?i_torque_control,
        MotorcontrolConfig &motorcontrol_config)

{
    if (isnull(i_torque_control))
        return;

    motorcontrol_config = i_torque_control.get_config();

    i_coe.set_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_DC_BUS_VOLTAGE, motorcontrol_config.dc_bus_voltage);
    i_coe.set_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_MOTOR_PHASES_INVERTED, motorcontrol_config.phases_inverted);
    i_coe.set_object_value(DICT_TORQUE_CONTROLLER, SUB_TORQUE_CONTROLLER_CONTROLLER_KP, motorcontrol_config.torque_P_gain);
    i_coe.set_object_value(DICT_TORQUE_CONTROLLER, SUB_TORQUE_CONTROLLER_CONTROLLER_KI, motorcontrol_config.torque_I_gain);
    i_coe.set_object_value(DICT_TORQUE_CONTROLLER, SUB_TORQUE_CONTROLLER_CONTROLLER_KD, motorcontrol_config.torque_D_gain);
    i_coe.set_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_POLE_PAIRS, motorcontrol_config.pole_pairs);
    i_coe.set_object_value(DICT_COMMUTATION_ANGLE_OFFSET, 0, motorcontrol_config.commutation_angle_offset);
    i_coe.set_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_PHASE_RESISTANCE, motorcontrol_config.phase_resistance);
    i_coe.set_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_PHASE_INDUCTANCE, motorcontrol_config.phase_inductance);
    i_coe.set_object_value(DICT_MOTOR_SPECIFIC_SETTINGS, SUB_MOTOR_SPECIFIC_SETTINGS_TORQUE_CONSTANT, motorcontrol_config.torque_constant);
    i_coe.set_object_value(DICT_MOTOR_RATED_CURRENT, 0, motorcontrol_config.rated_current);
    i_coe.set_object_value(DICT_MOTOR_RATED_TORQUE, 0, motorcontrol_config.rated_torque);
    i_coe.set_object_value(DICT_MAX_TORQUE, 0, (motorcontrol_config.max_torque*1000)/motorcontrol_config.rated_torque); // in 1/1000 of rated torque
    i_coe.set_object_value(DICT_APPLIED_TUNING_TORQUE_PERCENT, 0, motorcontrol_config.percent_offset_torque);
    /* Write protection limits */
    i_coe.set_object_value(DICT_PROTECTION, SUB_PROTECTION_MAX_CURRENT, motorcontrol_config.protection_limit_over_current);
    i_coe.set_object_value(DICT_PROTECTION, SUB_PROTECTION_MIN_DC_VOLTAGE, motorcontrol_config.protection_limit_under_voltage);
    i_coe.set_object_value(DICT_PROTECTION, SUB_PROTECTION_MAX_DC_VOLTAGE, motorcontrol_config.protection_limit_over_voltage);


    i_coe.set_object_value(DICT_HALL_SENSOR_1, SUB_HALL_SENSOR_STATE_ANGLE_0, motorcontrol_config.hall_state_angle[0]);
    i_coe.set_object_value(DICT_HALL_SENSOR_1, SUB_HALL_SENSOR_STATE_ANGLE_1, motorcontrol_config.hall_state_angle[1]);
    i_coe.set_object_value(DICT_HALL_SENSOR_1, SUB_HALL_SENSOR_STATE_ANGLE_2, motorcontrol_config.hall_state_angle[2]);
    i_coe.set_object_value(DICT_HALL_SENSOR_1, SUB_HALL_SENSOR_STATE_ANGLE_3, motorcontrol_config.hall_state_angle[3]);
    i_coe.set_object_value(DICT_HALL_SENSOR_1, SUB_HALL_SENSOR_STATE_ANGLE_4, motorcontrol_config.hall_state_angle[4]);
    i_coe.set_object_value(DICT_HALL_SENSOR_1, SUB_HALL_SENSOR_STATE_ANGLE_5, motorcontrol_config.hall_state_angle[5]);

    i_coe.set_object_value(DICT_HALL_SENSOR_2, SUB_HALL_SENSOR_STATE_ANGLE_0, motorcontrol_config.hall_state_angle[0]);
    i_coe.set_object_value(DICT_HALL_SENSOR_2, SUB_HALL_SENSOR_STATE_ANGLE_1, motorcontrol_config.hall_state_angle[1]);
    i_coe.set_object_value(DICT_HALL_SENSOR_2, SUB_HALL_SENSOR_STATE_ANGLE_2, motorcontrol_config.hall_state_angle[2]);
    i_coe.set_object_value(DICT_HALL_SENSOR_2, SUB_HALL_SENSOR_STATE_ANGLE_3, motorcontrol_config.hall_state_angle[3]);
    i_coe.set_object_value(DICT_HALL_SENSOR_2, SUB_HALL_SENSOR_STATE_ANGLE_4, motorcontrol_config.hall_state_angle[4]);
    i_coe.set_object_value(DICT_HALL_SENSOR_2, SUB_HALL_SENSOR_STATE_ANGLE_5, motorcontrol_config.hall_state_angle[5]);

    //FIXME: missing motorcontrol_config.protection_limit_over_temperature
}

void cm_default_config_profiler(
        client interface i_coe_communication i_coe,
        ProfilerConfig &profiler)
{
    i_coe.set_object_value(DICT_MAX_SOFTWARE_POSITION_RANGE_LIMIT, 1, profiler.min_position);
    i_coe.set_object_value(DICT_MAX_SOFTWARE_POSITION_RANGE_LIMIT, 2, profiler.max_position);
    i_coe.set_object_value(DICT_PROFILE_ACCELERATION, 0, profiler.acceleration);
    i_coe.set_object_value(DICT_PROFILE_DECELERATION, 0, profiler.deceleration);
    i_coe.set_object_value(DICT_MAX_PROFILE_VELOCITY, 0, profiler.max_velocity);
    i_coe.set_object_value(DICT_PROFILE_ACCELERATION, 0, profiler.max_acceleration);
    i_coe.set_object_value(DICT_MAX_PROFILE_VELOCITY, 0, profiler.velocity);
}

void cm_default_config_pos_velocity_control(
        client interface i_coe_communication i_coe,
        client interface MotionControlInterface i_motion_control
        )
{
    MotionControlConfig position_config = i_motion_control.get_motion_control_config();

    //limits
    i_coe.set_object_value(DICT_POSITION_RANGE_LIMITS, SUB_POSITION_RANGE_LIMITS_MIN_POSITION_RANGE_LIMIT, position_config.min_pos_range_limit);
    i_coe.set_object_value(DICT_POSITION_RANGE_LIMITS, SUB_POSITION_RANGE_LIMITS_MAX_POSITION_RANGE_LIMIT, position_config.max_pos_range_limit);
    i_coe.set_object_value(DICT_MAX_MOTOR_SPEED, 0, position_config.max_motor_speed);

    //if the internal polarity is inverted enable inverted position and velocity polarity bits in the DICT_POLARITY object
    if (position_config.polarity == MOTION_POLARITY_INVERTED) {
        i_coe.set_object_value(DICT_POLARITY, 0, MOTION_POLARITY_POSITION|MOTION_POLARITY_VELOCITY);
    }

    i_coe.set_object_value(DICT_MOTION_PROFILE_TYPE, 0, position_config.enable_profiler);

    i_coe.set_object_value(DICT_POSITION_CONTROL_STRATEGY, 0, position_config.position_control_strategy);

    i_coe.set_object_value(DICT_FILTER_COEFFICIENTS, SUB_FILTER_COEFFICIENTS_POSITION_FILTER_COEFFICIENT, position_config.filter);

    //position PID
    i_coe.set_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_CONTROLLER_KP, position_config.position_kp);
    i_coe.set_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_CONTROLLER_KI, position_config.position_ki);
    i_coe.set_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_CONTROLLER_KD, position_config.position_kd);
    i_coe.set_object_value(DICT_POSITION_CONTROLLER, SUB_POSITION_CONTROLLER_POSITION_INTEGRAL_LIMIT, position_config.position_integral_limit);
    i_coe.set_object_value(DICT_MOMENT_OF_INERTIA, 0, position_config.moment_of_inertia);

    //velocity PID
    i_coe.set_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_KP, position_config.velocity_kp);
    i_coe.set_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_KI, position_config.velocity_ki);
    i_coe.set_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_KD, position_config.velocity_kd);
    i_coe.set_object_value(DICT_VELOCITY_CONTROLLER, SUB_VELOCITY_CONTROLLER_CONTROLLER_INTEGRAL_LIMIT, position_config.velocity_integral_limit);

    /* Brake control settings */
    i_coe.set_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_BRAKE_RELEASE_STRATEGY, position_config.brake_release_strategy);
    i_coe.set_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_BRAKE_RELEASE_DELAY, position_config.brake_release_delay);
    i_coe.set_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_DC_BUS_VOLTAGE, position_config.dc_bus_voltage);
    i_coe.set_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_PULL_BRAKE_VOLTAGE, position_config.pull_brake_voltage);
    i_coe.set_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_PULL_BRAKE_TIME, position_config.pull_brake_time);
    i_coe.set_object_value(DICT_BREAK_RELEASE, SUB_BREAK_RELEASE_HOLD_BRAKE_VOLTAGE, position_config.hold_brake_voltage);

    i_motion_control.set_motion_control_config(position_config);
}
