/**
 * @file ecat_motor_drive.xc
 * @brief EtherCAT Motor Drive Server
 * @author Synapticon GmbH <support@synapticon.com>
 */

#include <ethercat_drive_service.h>
#include <refclk.h>
#include <cia402_wrapper.h>
#include <pdo_handler.h>
#include <statemachine.h>
#include <state_modes.h>
#include <profile.h>
#include <config_manager.h>

const char * state_names[] = {"u shouldn't see me",
"S_NOT_READY_TO_SWITCH_ON",
"S_SWITCH_ON_DISABLED",
"S_READY_TO_SWITCH_ON",
"S_SWITCH_ON",
"S_OPERATION_ENABLE",
"S_QUICK_STOP_ACTIVE",
"S_FAULT"
};

{int, int} static inline get_position_absolute(int sensor_select, interface HallInterface client ?i_hall,
                                                interface QEIInterface client ?i_qei, interface BISSInterface client ?i_biss, interface AMSInterface client ?i_ams)
{
    int actual_position;
    int direction;

    if (sensor_select == HALL_SENSOR) {
        actual_position = i_hall.get_hall_position_absolute();//get_hall_position_absolute(c_hall);
        direction = i_hall.get_hall_direction();
    } else if (sensor_select == QEI_SENSOR) { /* QEI */
        actual_position = i_qei.get_qei_position_absolute();//get_qei_position_absolute(c_qei);
        direction = i_qei.get_qei_direction();
    } else if (sensor_select == BISS_SENSOR) { /* BISS */
        { actual_position, void, void } = i_biss.get_biss_position();
        if (i_biss.get_biss_velocity() >= 0)
            direction = 1;
        else
            direction = -1;
    } else if (sensor_select == AMS_SENSOR) { /* AMS */
        { actual_position, void} = i_ams.get_ams_position();
        if (i_ams.get_ams_velocity() >= 0)
            direction = 1;
        else
            direction = -1;
    }

    return {actual_position, direction};
}

#define MAX_TIME_TO_WAIT_SDO      100000

static void sdo_wait_first_config(client interface i_coe_communication i_coe)
{
    timer t;
    unsigned int delay = MAX_TIME_TO_WAIT_SDO;
    unsigned int time;

    int sdo_configured = 0;

    while (sdo_configured == 0) {
        select {
            case i_coe.configuration_ready():
                printstrln("Master requests OP mode - cyclic operation is about to start.");
                sdo_configured = 1;
                break;
        }

        t when timerafter(time+delay) :> time;
    }

    /* comment in the read_od_config() function to print the object values */
    //read_od_config(i_coe);
    printstrln("Configuration finished, ECAT in OP mode - start cyclic operation");

    /* clear the notification before proceeding the operation */
    i_coe.configuration_done();
}

enum eDirection {
    DIRECTION_NEUTRAL = 0
    ,DIRECTION_CLK    = 1
    ,DIRECTION_CCLK   = -1
};

static int quick_stop_perform(int steps, enum eDirection direction,
                                ProfilerConfig &profiler_config,
                                interface PositionControlInterface client i_position_control)
{
    static int step = 0;

    if (step >= steps)
        return 1;

    int target_position = quick_stop_position_profile_generate(step, direction);
    i_position_control.set_position(position_limit(target_position,
            profiler_config.max_position,
            profiler_config.min_position));

    step++;

    return 0;
}

/*static */{ int, int } quick_stop_init(int op_mode,
                                int actual_velocity,
                                int sensor_resolution,
                                ProfilerConfig &profiler_config,
                                interface PositionControlInterface client i_position_control)
{

    if (op_mode == CST || op_mode == CSV) {
        /* TODO implement quick stop profile */
    }

    int actual_position = i_position_control.get_position();

    /* FIXME maybe get the velocity here directly? */
    if (actual_velocity < 0) {
        actual_velocity = -actual_velocity;
    }

    int steps = 0;
    /* WTF? WTF? WTF? */
    //if (actual_velocity >= 500)
    {

        int deceleration = profiler_config.max_deceleration;


        steps = init_quick_stop_position_profile(
                (actual_velocity * sensor_resolution) / 60,
                actual_position,
                (deceleration * sensor_resolution) / 60);

    }

    enum eDirection direction = DIRECTION_NEUTRAL;
    //{actual_position, direction} = get_position_absolute(sensor_select, i_hall, i_qei, i_biss, i_ams);

    return { steps, direction };
}

//#pragma xta command "analyze loop ecatloop"
//#pragma xta command "set required - 1.0 ms"

/* NOTE:
 * - op mode change only when we are in "Ready to Swtich on" state or below (basically op mode is set locally in this state).
 * - if the op mode signal changes in any other state it is ignored until we fall back to "Ready to switch on" state (Transition 2, 6 and 8)
 */
void ethercat_drive_service(ProfilerConfig &profiler_config,
                            chanend pdo_out, chanend pdo_in,
                            client interface i_coe_communication i_coe,
                            interface MotorcontrolInterface client i_commutation,
                            interface HallInterface client ?i_hall,
                            interface QEIInterface client ?i_qei,
                            interface BISSInterface client ?i_biss,
                            interface AMSInterface client ?i_ams,
                            interface GPIOInterface client ?i_gpio,
                            interface TorqueControlInterface client ?i_torque_control,
                            interface VelocityControlInterface client i_velocity_control,
                            interface PositionControlInterface client i_position_control)
{
    int i = 0;
    int mode = 40;
    int steps = 0;

    int target_torque = 0;
    int actual_torque = 0;
    int target_velocity = 0;
    int actual_velocity = 0;
    int target_position = 0;
    int actual_position = 0;

    enum eDirection direction = DIRECTION_NEUTRAL;
    int direction_temp;

    int position_ramp = 0;
    int prev_position = 0;

    int velocity_ramp = 0;
    int prev_velocity = 0;

    int torque_ramp = 0;
    int prev_torque = 0;

    int nominal_speed;
    timer t;

    int init = 0;
    int op_set_flag = 0;
    int op_mode = 0, op_mode_old = 0, op_mode_commanded_old = 0;

    ControlConfig position_ctrl_params;
    ControlConfig torque_ctrl_params;
    ControlConfig velocity_ctrl_params;

    QEIConfig qei_params;
    HallConfig hall_config;
    BISSConfig biss_config;
    AMSConfig ams_config;

    MotorcontrolConfig commutation_params;
    ctrl_proto_values_t InOut;

    int setup_loop_flag = 0;

    int ack = 0;
    int quick_active = 0;
    int mode_quick_flag = 0;
    int shutdown_ack = 0;
    int sensor_select = -1;

    int communication_active = 0;
    unsigned int c_time;
    int comm_inactive_flag = 0;
    int inactive_timeout_flag = 0;

    unsigned int time;
    int state, state_old;
    int statusword = 0, statusword_old = 0;
    int controlword = 0, controlword_old = 0;

    int status=0;
    int tmp=0;

    //int torque_offstate = 0;
    int mode_selected = 0; /* valid values: { 0, 1, 3, 100 } - WTF? */
    check_list checklist;

    int home_velocity = 0;
    int home_acceleration = 0;

    int limit_switch = -1;      // positive negative limit switches
    int reset_counter = 0;

    int home_state = 0;
    int safety_state = 0;
    int capture_position = 0;
    int current_position = 0;
    int home_offset = 0;
    int end_state = 0;
    int ctrl_state;
    int limit_switch_type;
    int homing_method;
    int polarity = 1;
    int homing_done = 0;
    state       = init_state(); // init state
    checklist   = init_checklist();
    InOut       = init_ctrl_proto();

    if (!isnull(i_hall))
        hall_config = i_hall.get_hall_config();
    if (!isnull(i_qei))
        qei_params = i_qei.get_qei_config();
    if (!isnull(i_biss))
        biss_config = i_biss.get_biss_config();
    if (!isnull(i_ams))
            ams_config = i_ams.get_ams_config();
    velocity_ctrl_params = i_velocity_control.get_velocity_control_config();
    MotorcontrolConfig motorcontrol_config = i_commutation.get_config();

 //ToDo parameters to be updated over ethercat:
 // hall_config
 // qei_params
 // biss_config
 // ams_config
 // velocity_ctrl_params
 // position_ctrl_params
 // torque_ctrl_params
 // motorcontrol_config
 // profiler_config
 // commutation_params
 //
 // sensor_select
 // nominal_speed
 // homing_method, limit_switch_type
 // polarity

    /* check if the slave enters the operation mode. If this happens we assume the configuration values are
     * written into the object dictionary. So we read the object dictionary values and continue operation.
     *
     * This should be done before we configure anything.
     */
    sdo_wait_first_config(i_coe);

    /* start operation */
    int read_configuration = 1;

    t :> time;
    while (1) {
//#pragma xta endpoint "ecatloop"
        /* FIXME reduce code duplication with above init sequence */
        /* Check if we reenter the operation mode. If so, update the configuration please. */
        select {
            case i_coe.configuration_ready():
                printstrln("Master requests OP mode - cyclic operation is about to start.");
                read_configuration = 1;
                break;
            default:
                break;
        }

        /* FIXME: When to update configuration values from OD? only do this in state "Ready to Switch on"? */
        if (read_configuration) {
            /* update structures */
            cm_sync_config_hall(i_coe, i_hall, hall_config);
            cm_sync_config_qei(i_coe, i_qei, qei_params);
            cm_sync_config_ams(i_coe, i_ams, ams_config);
            cm_sync_config_biss(i_coe, i_biss, biss_config);

            cm_sync_config_torque_control(i_coe, i_torque_control, torque_ctrl_params);
            cm_sync_config_velocity_control(i_coe, i_velocity_control, velocity_ctrl_params);
            cm_sync_config_position_control(i_coe, i_position_control, position_ctrl_params);

            cm_sync_config_profiler(i_coe, profiler_config);

            /* FIXME commutation_params and motorcontrol_config are similar but not the same */
            cm_sync_config_motor_control(i_coe, i_commutation, commutation_params);
            cm_sync_config_motor_commutation(i_coe, motorcontrol_config);

            /* Update values with current configuration */
            polarity = profiler_config.polarity;
            /* FIXME use cm_sync_config_{biss,ams}() */
            biss_config.pole_pairs = i_coe.get_object_value(CIA402_MOTOR_SPECIFIC, 3);
            ams_config.pole_pairs  = i_coe.get_object_value(CIA402_MOTOR_SPECIFIC, 3);

            nominal_speed = i_coe.get_object_value(CIA402_MOTOR_SPECIFIC, 4);
            limit_switch_type = i_coe.get_object_value(LIMIT_SWITCH_TYPE, 0);
            homing_method = i_coe.get_object_value(CIA402_HOMING_METHOD, 0);

            /* FIXME this is weired, 3 === 2? is this python? */
            sensor_select = i_coe.get_object_value(CIA402_SENSOR_SELECTION_CODE, 0);
            if(sensor_select == 2 || sensor_select == 3)
                sensor_select = 2; //qei

            i_velocity_control.set_velocity_sensor(sensor_select);
            i_position_control.set_position_sensor(sensor_select);

            /* Configuration of GPIO Digital ports for limit switches */
            if (!isnull(i_gpio)) {
                i_gpio.config_dio_input(0, SWITCH_INPUT_TYPE, limit_switch_type);
                i_gpio.config_dio_input(1, SWITCH_INPUT_TYPE, limit_switch_type);
                i_gpio.config_dio_done();//end_config_gpio(c_gpio);
            }

            read_configuration = 0;
            i_coe.configuration_done();
        }

        /* Read/Write packets to ethercat Master application */
        communication_active = ctrlproto_protocol_handler_function(pdo_out, pdo_in, InOut);

        if (communication_active == 0) {
            if (comm_inactive_flag == 0) {
                comm_inactive_flag = 1;
                t :> c_time;
            } else if (comm_inactive_flag == 1) {
                unsigned ts_comm_inactive;
                t :> ts_comm_inactive;
                if (ts_comm_inactive - c_time > 1*SEC_STD) {
                    //printstrln("comm inactive timeout");
                    t :> c_time;
                    t when timerafter(c_time + 2*SEC_STD) :> c_time;
                    inactive_timeout_flag = 1;
                }
            }
        } else if (communication_active >= 1) {
            comm_inactive_flag = 0;
            inactive_timeout_flag = 0;
        }

        /*********************************************************************************
         * If communication is inactive, trigger quick stop mode if motor is in motion 
         *********************************************************************************/
        if (inactive_timeout_flag == 1) {
            //printstrln("Triggering quick stop mode");

            if(controlword != controlword_old
                    || state != state_old
                    || statusword != statusword_old
                    || InOut.operation_mode != op_mode_commanded_old
                    || op_mode != op_mode_old) {
                printf("Inactive_COMM!!!, Control_word: %d  |  State: %s  |   Statusword: %d  |   Op_mode_commanded %d, Op_mode_assigned %d\n",
                        controlword, state_names[state], statusword, InOut.operation_mode, op_mode);
            }

            controlword_old = controlword;
            state_old = state;
            statusword_old = statusword;
            op_mode_commanded_old = InOut.operation_mode;
            op_mode_old = op_mode;

            int sensor_resolution = 0;
            int actual_velocity = 0;
            if (sensor_select == HALL_SENSOR) {
                sensor_resolution = hall_config.pole_pairs * HALL_TICKS_PER_ELECTRICAL_ROTATION;//max_ticks_per_turn;
                actual_velocity = i_hall.get_hall_velocity();
            } else if (sensor_select == QEI_SENSOR){    /* QEI */
                sensor_resolution = qei_params.ticks_resolution * QEI_CHANGES_PER_TICK;
                actual_velocity = i_qei.get_qei_velocity();
            } else if (sensor_select == BISS_SENSOR){    /* BiSS */
                sensor_resolution = (1 << biss_config.singleturn_resolution);
                actual_velocity = i_biss.get_biss_velocity();
            } else if (sensor_select == AMS_SENSOR){    /* AMS */
                sensor_resolution = (1 << ams_config.resolution_bits);
                actual_velocity = i_ams.get_ams_velocity();
            }

            { actual_position, direction } = get_position_absolute(sensor_select, i_hall, i_qei, i_biss, i_ams);
            { steps, direction_temp } = quick_stop_init(op_mode, actual_velocity, sensor_resolution, profiler_config, i_position_control);
            quick_active = 1;

            /* FIXME safe to get rid of? */
            mode_selected = 0;
            setup_loop_flag = 0;
            op_set_flag = 0;
            op_mode = 256;      /* FIXME: why 256? */
        }


        /*********************************************************************************
         * EtherCAT communication is Active
         *********************************************************************************/
        if (comm_inactive_flag == 0) {
            //printstrln("EtherCAT comm active");
            /* Read controlword from the received from EtherCAT Master application */
            controlword = InOut.control_word;

            /* Check states of the motor drive, sensor drive and control servers */
            update_checklist(checklist, mode, i_commutation, i_hall, i_qei, i_biss, i_ams, null,
                             i_torque_control, i_velocity_control, i_position_control);

            /* Update state machine */
            state = get_next_state(state, checklist, controlword, 0);

            /* Update statusword sent to the EtherCAT Master Application */
            statusword = update_statusword(statusword, state, ack, quick_active, shutdown_ack);
            InOut.status_word = statusword;

            if(controlword != controlword_old
                    || state != state_old
                    || statusword != statusword_old
                    || InOut.operation_mode != op_mode_commanded_old
                    || op_mode != op_mode_old) {
                printf("Active_COMM, Control_word: %d  |  State: %s  |   Statusword: %d  |   Op_mode_commanded %d, Op_mode_assigned %d\n",
                        controlword, state_names[state], statusword, InOut.operation_mode, op_mode);
            }

            controlword_old       = controlword;
            state_old             = state;
            statusword_old        = statusword;
            op_mode_commanded_old = InOut.operation_mode;
            op_mode_old           = op_mode;



            /* FIXME - deprecated since the configuration is checked in the beginning of the loop
             * WRONG! There is no controlword '5' in std. controls, only
             * possibility "Disable Voltage" but Bit 0 and 2 are don't care!
             * Besides, op mode 105 is in the reserved are of valid values! */
            if (setup_loop_flag == 0) {
                if (controlword == 6) {
                    InOut.operation_mode_display = 105;
                }
                /* Read Motor Configuration sent from the EtherCAT Master Application */
                if (controlword == 5) {
                    setup_loop_flag = 1;
                    op_set_flag = 0;
                }
            }

            /* FIXME unify this, either read everything in the beginning but only fetch the value once!
             * BTW, where is torque and position read? */
            /* Read Position Sensor */
            if (sensor_select == HALL_SENSOR && !isnull(i_hall)) {
                actual_velocity = i_hall.get_hall_velocity();
            } else if (sensor_select == QEI_SENSOR && !isnull(i_qei)) {
                actual_velocity = i_qei.get_qei_velocity();
               //printintln(actual_velocity);
            } else if (sensor_select == BISS_SENSOR && !isnull(i_biss)) {
                actual_velocity = i_biss.get_biss_velocity();
            } else if (sensor_select == AMS_SENSOR && !isnull(i_ams)) {
                actual_velocity = i_ams.get_ams_velocity();
            }
            send_actual_velocity(actual_velocity * polarity, InOut);

            /* ################################
             * Error Handling
             * ################################ */

            if (!checklist.fault)
            {
#if 0 /* the i_adc got lost somehow, somewhere... */
                /* Temperature */
                if (i_adc.get_temperature() > TEMP_THRESHOLD) {
                    checklist.fault = true;

                }
#endif

                profiler_config.max_velocity;
                /* Speed - FIXME add check if actual speed is > than speed limits */

                /* Over current - FIXME add check if we have over-current - from where? */

                /* Over voltage - FIXME add check for over-voltage - from where? */
            }


            if (mode_selected == 0) {
                /* Select an operation mode requested from EtherCAT Master Application */
                switch (InOut.operation_mode) {
                    /* Cyclic synchronous position mode initialization */
                //FixMe: initialization should take place before we start PDO communication
                case CSP:
                    if (op_set_flag == 0) {
                        ctrl_state = i_velocity_control.check_busy();
                        if (ctrl_state == 1) {
                            i_velocity_control.disable_velocity_ctrl();
                        }
                        init_position_control(i_position_control);
                    }
                    if (i_position_control.check_busy() == INIT) {
                        op_set_flag = 1;
                        mode_selected = 1;
                        mode_quick_flag = 10;
                        op_mode = CSP;
                        ack = 0;
                        shutdown_ack = 0;

                        update_csp_param_ecat(profiler_config, i_coe);
                        InOut.operation_mode_display = CSP;
                    }
                    break;

                    /* Cyclic synchronous velocity mode initialization */
                case CSV:   //csv mode index
                    break;

                    /* Cyclic synchronous torque mode initialization */
                case CST:
                    break;
                }
            }

            /* After operation mode is selected the loop enters a continuous operation
             * until the operation is shutdown */
            if (mode_selected == 1) {
                switch (controlword) {
                case QUICK_STOP:
                    int sensor_resolution = 0;
                    int actual_velocity = 0;
                    if (sensor_select == HALL_SENSOR) {
                        sensor_resolution = hall_config.pole_pairs * HALL_TICKS_PER_ELECTRICAL_ROTATION;//max_ticks_per_turn;
                        actual_velocity = i_hall.get_hall_velocity();
                    } else if (sensor_select == QEI_SENSOR){    /* QEI */
                        sensor_resolution = qei_params.ticks_resolution * QEI_CHANGES_PER_TICK;
                        actual_velocity = i_qei.get_qei_velocity();
                    } else if (sensor_select == BISS_SENSOR){    /* BiSS */
                        sensor_resolution = (1 << biss_config.singleturn_resolution);
                        actual_velocity = i_biss.get_biss_velocity();
                    } else if (sensor_select == AMS_SENSOR){    /* AMS */
                        sensor_resolution = (1 << ams_config.resolution_bits);
                        actual_velocity = i_ams.get_ams_velocity();
                    }

                    { actual_position, direction } = get_position_absolute(sensor_select, i_hall, i_qei, i_biss, i_ams);
                    { steps, direction_temp } = quick_stop_init(op_mode, actual_velocity, sensor_resolution, profiler_config, i_position_control);
                    state = get_next_state(state, checklist, controlword, QUICK_STOP_INIT);
                    break;

                    /* continuous controlword */
                case SWITCH_ON: //switch on cyclic
                    if (op_mode == CSV) {
                        //ToDo: implement CSV
                    } else if (op_mode == CST) {
                        //ToDo: implement CST
                    } else if (op_mode == CSP) {
                    //printstrln("SWITCH ON: cyclic position mode");
                        target_position = get_target_position(InOut);
                        i_position_control.set_position(position_limit( (target_position) * profiler_config.polarity,
                                                        profiler_config.max_position, profiler_config.min_position));
                       // set_position_csp(profiler_config, target_position, 0, 0, 0, i_position_control);

                        actual_position = i_position_control.get_position() * profiler_config.polarity;//cyclic_sync_position_config.velocity_config.polarity;
                        send_actual_position(actual_position, InOut);
                        //printintln(actual_position);
                        //safety_state = read_gpio_digital_input(c_gpio, 1);        // read port 1
                        //value = (port_3_value<<3 | port_2_value<<2 | port_1_value <<1| safety_state );  pack values if more than one port inputs
                    }
                    break;

                case SHUTDOWN:
                    if (op_mode == CST) {
                        //ToDo implement shutdown for CST
                    } else if (op_mode == CSV) {
                        //ToDo implement shutdown for CSV
                    } else if (op_mode == CSP) {
                        //FixMe: verify if we are doing it right
                        i_position_control.disable_position_ctrl();
                        //printstrln("CSP disabled.");
                        shutdown_ack = 1;
                        op_set_flag = 0;
                        init = 0;
                        mode_selected = 0;  // to reenable the op selection and reset the controller
                        setup_loop_flag = 0;
                    }
                    break;
                }
            }

            /* If we are in state S_QUICK_STOP_ACTIVE then we perform the quick stop steps! */
            if (state == S_QUICK_STOP_ACTIVE) {
                int ret = quick_stop_perform(steps, direction, profiler_config, i_position_control);
                if (ret != 0) {
                    state = get_next_state(state, checklist, 0, QUICK_STOP_FINISHED);
                }
            }

            /* quick stop controlword routine */
            else if (mode_selected == 3) { // non interrupt
                //perform_quick_stop();

            } else if (mode_selected == 100) {
                if (mode_quick_flag == 0)
                    quick_active = 1;

                if (op_mode == CST) {
                    //Here was just sending toque feedback, but why not always?
                } else if (op_mode == CSV) {
                    //Here was just sending velocity feedback, but why not always?
                }
                //FixMe: what is logic here?
                switch (InOut.operation_mode) {
                case 100:
                    mode_selected = 0;
                    quick_active = 0;
                    mode_quick_flag = 1;
                    InOut.operation_mode_display = 100;
                    break;
                }
            }

            /* Read Torque and Position */
            {actual_position, direction} = get_position_absolute(sensor_select, i_hall, i_qei, i_biss, i_ams);

            if(motorcontrol_config.commutation_method == FOC){
                send_actual_torque( i_commutation.get_torque_actual(), InOut );
            } else {
                if(!isnull(i_torque_control))
                    send_actual_torque( i_torque_control.get_torque() * polarity, InOut );
            }
            //send_actual_torque( get_torque(c_torque_ctrl) * polarity, InOut );
            send_actual_position(actual_position * polarity, InOut);
            t when timerafter(time + MSEC_STD) :> time;
        }

//#pragma xta endpoint "ecatloop_stop"
    }
}
